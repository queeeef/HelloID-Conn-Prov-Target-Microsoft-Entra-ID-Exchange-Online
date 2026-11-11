#!/usr/bin/env python3
"""
Stateful fake of the parts of Microsoft Graph and the Entra token endpoint that the connector uses.

The connector scripts run unmodified: graph.microsoft.com and login.microsoftonline.com are pointed
at this server (127.0.0.1 in /etc/hosts) and it serves HTTPS with a certificate from a CA the
runner trusts.

Endpoints (v1.0):
  POST /{tenant}/oauth2/token                                   client credentials token
  GET  /groups?$filter=...                                      paged, M365 / security filters of the import
  GET  /groups/{id}/members[/microsoft.graph.user]?$top=        keyset paged
  POST /$batch                                                  up to 20 sub-requests, throttled individually
  GET  /users/{id}
  POST /groups/{id}/members/$ref                                add member
  DELETE /groups/{id}/members/{id}/$ref                         remove member

Throttling model (all limits are per app, like Graph):
  * a token bucket (FAKE_RATE requests/second, FAKE_BURST capacity). Every request and every batch
    sub-request takes one token; when empty the request gets 429 with Retry-After.
  * random noise: FAKE_RANDOM_429 and FAKE_RANDOM_503 (probability per request).
  * a simulated intranet that takes FAKE_INTRANET_RPS tokens per second from the same bucket and
    counts how often it was refused, to measure how the connector's load affects other apps.
  * retries of the same request before its Retry-After expired are counted as "early retries".

Test-only endpoints, not throttled: GET /_fake/member, /_fake/snapshot, /_fake/stats, POST /_fake/reset-stats
"""
import json
import os
import random
import re
import ssl
import sys
import threading
import time
import uuid
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qsl, unquote, urlsplit

LOCK = threading.RLock()
RNG = random.Random(int(os.environ.get("FAKE_SEED", "7")))


class TokenBucket:
    def __init__(self, rate, burst):
        self.rate, self.capacity = rate, burst
        self.tokens, self.updated = float(burst), time.monotonic()

    def take(self):
        """Returns 0 when a token was taken, otherwise the seconds until one is available."""
        now = time.monotonic()
        self.tokens = min(self.capacity, self.tokens + (now - self.updated) * self.rate)
        self.updated = now
        if self.tokens >= 1:
            self.tokens -= 1
            return 0.0
        return (1 - self.tokens) / self.rate


class Tenant:
    def __init__(self, data):
        self.users = {u["id"]: u for u in data["users"]}
        self.groups = {g["id"]: g for g in data["groups"]}
        self.members = {gid: set(ids) for gid, ids in data["members"].items()}
        self.group_order = sorted(self.groups)


class State:
    def __init__(self, tenant):
        self.tenant = tenant
        self.bucket = TokenBucket(float(os.environ.get("FAKE_RATE", "250")), float(os.environ.get("FAKE_BURST", "500")))
        self.random_429 = float(os.environ.get("FAKE_RANDOM_429", "0.003"))
        self.random_503 = float(os.environ.get("FAKE_RANDOM_503", "0.002"))
        self.intranet_rps = float(os.environ.get("FAKE_INTRANET_RPS", "20"))
        self.nonmember_message_id = os.environ.get("FAKE_NONMEMBER_MESSAGE_ID", "member")  # 'member' or 'group'
        self.retry_after_until = {}
        self.reset_stats()

    def reset_stats(self):
        self.stats = Counter()
        self.status_by_endpoint = Counter()
        self.phase_started = time.time()

    def admit(self, key):
        """Throttling decision for one request or sub-request. Returns (status, retry_after) or None."""
        now = time.monotonic()
        until = self.retry_after_until.get(key)
        if until is not None and now < until - 0.05:
            self.stats["early_retries"] += 1
        wait = self.bucket.take()
        if wait > 0:
            retry_after = max(1, int(wait + 0.999))
            self.retry_after_until[key] = now + retry_after
            self.stats["throttled_bucket"] += 1
            return 429, retry_after
        roll = RNG.random()
        if roll < self.random_429:
            self.retry_after_until[key] = now + 1
            self.stats["throttled_random"] += 1
            return 429, 1
        if roll < self.random_429 + self.random_503:
            self.stats["transient_503"] += 1
            return 503, None
        self.retry_after_until.pop(key, None)
        return None


STATE = None


def graph_error(status, code, message):
    return status, {"error": {"code": code, "message": message,
                              "innerError": {"date": time.strftime("%Y-%m-%dT%H:%M:%S"), "request-id": str(uuid.uuid4())}}}


def not_found(resource_id):
    return graph_error(404, "Request_ResourceNotFound",
                       f"Resource '{resource_id}' does not exist or one of its queried reference-property objects are not present.")


def group_matches_filter(group, filt):
    if not filt:
        return True
    if filt.startswith("groupTypes/any(c:c+eq+'Unified')"):
        return "Unified" in group["groupTypes"]
    if "securityEnabled eq true" in filt:
        return ("DynamicMembership" not in group["groupTypes"] and group["onPremisesSyncEnabled"] is None
                and group["mailEnabled"] is False and group["securityEnabled"] is True)
    raise ValueError(f"unsupported $filter: {filt}")


def page_params(query):
    top = int(query.get("$top", "100"))
    return min(max(top, 1), 999), query.get("$skiptoken")


def handle_graph(method, path, query, body):
    """Graph semantics for one (sub-)request. path is relative to /v1.0, e.g. /groups/{id}/members."""
    tenant = STATE.tenant
    parts = [p for p in path.split("/") if p]

    if method == "GET" and parts == ["groups"]:
        try:
            matching = [gid for gid in tenant.group_order if group_matches_filter(tenant.groups[gid], query.get("$filter"))]
        except ValueError as exc:
            return graph_error(400, "Request_UnsupportedQuery", str(exc))
        top, skip = page_params(query)
        start = matching.index(skip) + 1 if skip in matching else 0
        page = matching[start:start + top]
        result = {"value": [{"id": gid, "displayName": tenant.groups[gid]["displayName"],
                             "description": tenant.groups[gid]["description"]} for gid in page]}
        if start + top < len(matching):
            result["@odata.nextLink"] = (f"https://graph.microsoft.com/v1.0/groups?$filter={query.get('$filter', '')}"
                                         f"&$top={top}&$skiptoken={page[-1]}")
        return 200, result

    if method == "GET" and len(parts) in (3, 4) and parts[0] == "groups" and parts[2] == "members":
        gid = parts[1]
        if gid not in tenant.groups:
            return not_found(gid)
        top, skip = page_params(query)
        ordered = sorted(tenant.members[gid])
        start = 0
        if skip:
            start = next((i for i, uid in enumerate(ordered) if uid > skip), len(ordered))
        page = ordered[start:start + top]
        result = {"value": [{"@odata.type": "#microsoft.graph.user", "id": uid} for uid in page]}
        if start + top < len(ordered):
            cast = "/microsoft.graph.user" if len(parts) == 4 else ""
            result["@odata.nextLink"] = (f"https://graph.microsoft.com/v1.0/groups/{gid}/members{cast}"
                                         f"?$select=id&$top={top}&$skiptoken={page[-1]}")
        return 200, result

    if method == "GET" and len(parts) == 2 and parts[0] == "users":
        user = tenant.users.get(parts[1])
        return (200, user) if user else not_found(parts[1])

    if method == "POST" and parts[0:1] == ["groups"] and parts[2:] == ["members", "$ref"]:
        gid = parts[1]
        ref = (body or {}).get("@odata.id", "")
        uid = ref.rstrip("/").split("/")[-1]
        if gid not in tenant.groups:
            return not_found(gid)
        if uid not in tenant.users:
            return not_found(uid)
        if uid in tenant.members[gid]:
            return graph_error(400, "Request_BadRequest",
                               "One or more added object references already exist for the following modified properties: 'members'.")
        tenant.members[gid].add(uid)
        STATE.stats["writes_add"] += 1
        return 204, None

    if method == "DELETE" and parts[0:1] == ["groups"] and len(parts) == 5 and parts[2] == "members" and parts[4] == "$ref":
        gid, uid = parts[1], parts[3]
        if gid not in tenant.groups:
            return not_found(gid)
        if uid not in tenant.members[gid]:
            return not_found(uid if STATE.nonmember_message_id == "member" else gid)
        tenant.members[gid].discard(uid)
        STATE.stats["writes_remove"] += 1
        return 204, None

    return graph_error(400, "BadRequest", f"Fake Graph does not implement {method} /{'/'.join(parts)}")


def endpoint_label(method, path):
    label = re.sub(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", "{id}", path)
    return f"{method} {label}"


def intranet_loop():
    while True:
        if STATE.intranet_rps <= 0:
            time.sleep(1)
            continue
        time.sleep(1 / STATE.intranet_rps)
        with LOCK:
            STATE.stats["intranet_requests"] += 1
            if STATE.bucket.take() > 0:
                STATE.stats["intranet_throttled"] += 1


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_json(self, status, payload, headers=None):
        data = b"" if payload is None else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if data:
            self.wfile.write(data)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        return raw.decode() if raw else ""

    def dispatch(self, method):
        raw_body = self.read_body()
        split = urlsplit(self.path)
        host = (self.headers.get("Host") or "").split(":")[0]
        query = {k: v for k, v in parse_qsl(split.query, keep_blank_values=True)} if split.query else {}
        path = split.path
        if "//" in path:
            with LOCK:
                STATE.stats["double_slash_paths"] += 1
            path = re.sub("/+", "/", path)

        if path.startswith("/_fake/"):
            return self.fake_endpoint(method, path, query)

        if host == "login.microsoftonline.com" and method == "POST" and path.endswith("/oauth2/token"):
            with LOCK:
                STATE.stats["token_requests"] += 1
            return self.send_json(200, {"token_type": "Bearer", "expires_in": 3599, "access_token": "fake-" + uuid.uuid4().hex})

        if not path.startswith("/v1.0/"):
            return self.send_json(*graph_error(400, "BadRequest", f"Unsupported path {path}"))
        if not (self.headers.get("Authorization") or "").startswith("Bearer "):
            return self.send_json(*graph_error(401, "InvalidAuthenticationToken", "Access token is empty."))
        rel = path[len("/v1.0"):]

        if method == "POST" and rel == "/$batch":
            return self.batch(raw_body)

        # Raw query string decoding: Graph treats '+' in $filter literally (c:c+eq+'Unified')
        query = {k: unquote(v) for k, v in (kv.split("=", 1) for kv in split.query.split("&") if "=" in kv)}
        body = json.loads(raw_body) if raw_body.strip() else None
        with LOCK:
            label = endpoint_label(method, rel)
            throttle = STATE.admit(f"{method} {self.path}")
            if throttle:
                status, retry_after = throttle
                STATE.status_by_endpoint[f"{label} {status}"] += 1
                if status == 429:
                    return self.send_json(*graph_error(429, "TooManyRequests", "Too many requests."), headers={"Retry-After": str(retry_after)})
                return self.send_json(*graph_error(503, "serviceNotAvailable", "Service unavailable."))
            status, payload = handle_graph(method, rel, query, body)
            STATE.status_by_endpoint[f"{label} {status}"] += 1
        self.send_json(status, payload)

    def batch(self, raw_body):
        requests = json.loads(raw_body).get("requests", [])
        if len(requests) > 20:
            return self.send_json(*graph_error(400, "BadRequest", "The number of requests in a batch cannot exceed 20."))
        responses = []
        with LOCK:
            STATE.stats["batch_calls"] += 1
            for sub in requests:
                url = sub["url"]
                split = urlsplit(url)
                query = {k: unquote(v) for k, v in (kv.split("=", 1) for kv in split.query.split("&") if "=" in kv)}
                label = "BATCH " + endpoint_label(sub["method"], split.path)
                throttle = STATE.admit(f"{sub['method']} {url}")
                if throttle:
                    status, retry_after = throttle
                    error = graph_error(status, "TooManyRequests" if status == 429 else "serviceNotAvailable", "Simulated throttling")[1]
                    headers = {"Retry-After": str(retry_after)} if retry_after else {}
                    responses.append({"id": sub["id"], "status": status, "headers": headers, "body": error})
                else:
                    status, payload = handle_graph(sub["method"], split.path, query, sub.get("body"))
                    responses.append({"id": sub["id"], "status": status, "headers": {"Content-Type": "application/json"}, "body": payload})
                STATE.status_by_endpoint[f"{label} {status}"] += 1
                STATE.stats["batch_subrequests"] += 1
        RNG.shuffle(responses)  # Graph does not guarantee response order
        self.send_json(200, {"responses": responses})

    def fake_endpoint(self, method, path, query):
        tenant = STATE.tenant
        with LOCK:
            if path == "/_fake/member":
                gid, uid = query.get("group"), query.get("user")
                return self.send_json(200, {"groupExists": gid in tenant.groups, "userExists": uid in tenant.users,
                                            "member": gid in tenant.members and uid in tenant.members[gid]})
            if path == "/_fake/snapshot":
                importable = {gid: sorted(tenant.members[gid]) for gid, g in tenant.groups.items()
                              if group_matches_filter(g, "groupTypes/any(c:c+eq+'Unified')") or group_matches_filter(g, "securityEnabled eq true")}
                return self.send_json(200, importable)
            if path == "/_fake/stats":
                elapsed = time.time() - STATE.phase_started
                return self.send_json(200, {"elapsedSeconds": round(elapsed, 1), "stats": STATE.stats,
                                            "statusByEndpoint": dict(sorted(STATE.status_by_endpoint.items())),
                                            "config": {"rate": STATE.bucket.rate, "burst": STATE.bucket.capacity,
                                                       "random429": STATE.random_429, "random503": STATE.random_503,
                                                       "intranetRps": STATE.intranet_rps,
                                                       "nonMemberMessageId": STATE.nonmember_message_id}})
            if path == "/_fake/reset-stats" and method == "POST":
                STATE.reset_stats()
                return self.send_json(200, {"ok": True})
        self.send_json(404, {"error": "unknown fake endpoint"})

    def do_GET(self):
        self.dispatch("GET")

    def do_POST(self):
        self.dispatch("POST")

    def do_DELETE(self):
        self.dispatch("DELETE")


def main():
    global STATE
    tenant_file, cert, key = sys.argv[1], sys.argv[2], sys.argv[3]
    port = int(os.environ.get("FAKE_PORT", "443"))
    STATE = State(Tenant(json.load(open(tenant_file))))
    threading.Thread(target=intranet_loop, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(f"Fake Graph listening on 127.0.0.1:{port} with {len(STATE.tenant.users)} users and {len(STATE.tenant.groups)} groups", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()

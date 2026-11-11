#!/usr/bin/env python3
"""Checks that the fake Graph behaves like the real endpoints the connector depends on. Exits non-zero on failure."""
import http.client
import json
import os
import ssl
import sys

PORT = int(os.environ.get("FAKE_PORT", "443"))
CA = sys.argv[1]
TENANT = json.load(open(sys.argv[2]))
CTX = ssl.create_default_context(cafile=CA)


def call(method, path, body=None, host="graph.microsoft.com", auth=True):
    conn = http.client.HTTPSConnection("127.0.0.1", PORT, context=CTX, timeout=30)
    # TLS must validate for the real hostname, as PowerShell will
    conn.sock = CTX.wrap_socket(__import__("socket").create_connection(("127.0.0.1", PORT)), server_hostname=host)
    headers = {"Host": host, "Content-Type": "application/json"}
    if auth:
        headers["Authorization"] = "Bearer x"
    conn.request(method, path, body=json.dumps(body) if body is not None else None, headers=headers)
    resp = conn.getresponse()
    raw = resp.read()
    return resp.status, dict(resp.getheaders()), (json.loads(raw) if raw else None)


failures = []


def check(name, condition, detail=""):
    print(("PASS " if condition else "FAIL ") + name + (f"  [{detail}]" if detail and not condition else ""))
    if not condition:
        failures.append(name)


group_by_name = {g["displayName"]: g for g in TENANT["groups"]}
importable = [g for g in TENANT["groups"] if g["kind"] in ("security", "m365")]
user = TENANT["users"][1]["id"]
small_group = group_by_name["APP-Figma-Admins"]["id"]
all_employees = group_by_name["SG-All-Employees"]["id"]

s, _, b = call("POST", "/tenant/oauth2/token", {}, host="login.microsoftonline.com", auth=False)
check("token endpoint", s == 200 and b["access_token"].startswith("fake-"))

s, _, b = call("GET", "/v1.0/groups?$filter=groupTypes/any(c:c+eq+'Unified')&$select=id,displayName,description&$top=999")
check("M365 group filter", s == 200 and len(b["value"]) == sum(1 for g in importable if g["kind"] == "m365"), f"{s} {len((b or {}).get('value', []))}")

s, _, b = call("GET", "/v1.0/groups?$filter=NOT(groupTypes/any(c:c+eq+'DynamicMembership'))%20and%20onPremisesSyncEnabled%20eq%20null%20and%20mailEnabled%20eq%20false%20and%20securityEnabled%20eq%20true&$select=id&$top=999")
check("security group filter excludes dynamic/synced/mail-enabled", s == 200 and len(b["value"]) == sum(1 for g in importable if g["kind"] == "security"), f"{s}")

ids, path, pages = [], f"/v1.0/groups/{all_employees}/members/microsoft.graph.user?$select=id&$top=999", 0
while path:
    s, _, b = call("GET", path)
    ids += [m["id"] for m in b["value"]]
    pages += 1
    next_link = b.get("@odata.nextLink")
    path = next_link.replace("https://graph.microsoft.com", "") if next_link else None
check("member paging returns every member once", len(ids) == 5000 and len(set(ids)) == 5000 and pages == 6, f"{len(ids)} {pages}")

s, _, _ = call("GET", f"/v1.0/users/{user}?$select=*")
check("get user", s == 200)
s, _, b = call("GET", f"/v1.0/users/{TENANT['deletedUserIds'][0]}?$select=*")
check("get deleted user is 404 Request_ResourceNotFound", s == 404 and b["error"]["code"] == "Request_ResourceNotFound")

ref = {"@odata.id": f"https://graph.microsoft.com/v1.0/users/{user}"}
s, _, _ = call("POST", f"/v1.0/groups/{small_group}/members/$ref", ref)
check("add member", s == 204, str(s))
s, _, b = call("POST", f"/v1.0/groups/{small_group}/members/$ref", ref)
check("add existing member is 400 'already exist'", s == 400 and "already exist" in b["error"]["message"])
s, _, _ = call("DELETE", f"//v1.0/groups/{small_group}/members/{user}/$ref")
check("remove member (double slash path, as revokePermission.ps1 sends it)", s == 204, str(s))
s, _, b = call("DELETE", f"/v1.0/groups/{small_group}/members/{user}/$ref")
check("remove non-member is 404", s == 404 and b["error"]["code"] == "Request_ResourceNotFound")

s, _, b = call("POST", "/v1.0/$batch", {"requests": [
    {"id": "0", "method": "GET", "url": f"/groups/{small_group}/members/microsoft.graph.user?$select=id&$top=999"},
    {"id": "1", "method": "GET", "url": f"/groups/{TENANT['deletedGroups'][0]['id']}/members?$top=5"}]})
statuses = {r["id"]: r["status"] for r in b["responses"]}
check("batch returns per-sub-request status", s == 200 and statuses == {"0": 200, "1": 404}, str(statuses))

s, _, b = call("GET", "/_fake/stats")
check("stats endpoint", s == 200 and "stats" in b)
print(json.dumps(b["stats"]))

if failures:
    print(f"{len(failures)} smoke test(s) failed")
    sys.exit(1)
print("Fake Graph smoke test passed")

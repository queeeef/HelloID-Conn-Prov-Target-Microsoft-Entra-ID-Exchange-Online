#!/usr/bin/env python3
"""
Summarizes dry-run output directories.

  analyze.py <dir> [<dir> ...]     prints a Markdown report and writes summary.json into the first directory's parent

Each directory may contain:
  results-*.jsonl                  per-operation results from Invoke-DryRunWorker.ps1
  import-<label>.json              import output from Invoke-DryRunImport.ps1
  snapshot-<label>.json            the fake tenant's real memberships at that moment
  stats-<phase>.json               fake Graph counters per phase
Imports are compared with the snapshot of the same label; import-pressure-* with snapshot-initial.
"""
import json
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path


def failure_cause(audit):
    text = (audit or "")
    lowered = text.lower()
    if "toomanyrequests" in lowered or "too many requests" in lowered:
        return "throttled (429)"
    if "servicenotavailable" in lowered or "service unavailable" in lowered:
        return "transient (503)"
    if "could not be found, possibly" in lowered:
        return "account not found"
    if "request_resourcenotfound" in lowered or "does not exist" in lowered:
        return "resource not found (404)"
    return "other: " + text[:120]


def compare_import(imported, snapshot):
    expected = {gid: sorted(members) for gid, members in snapshot.items() if members}
    reported = {gid: sorted(members) for gid, members in (imported.get("permissions") or {}).items()}
    missing = [gid for gid in expected if gid not in reported]
    extra = [gid for gid in reported if gid not in expected]
    wrong = [gid for gid in expected if gid in reported and reported[gid] != expected[gid]]
    return {
        "expectedGroups": len(expected), "reportedGroups": len(reported), "missingGroups": len(missing),
        "extraGroups": len(extra), "groupsWithWrongMembers": len(wrong),
        "missingMemberships": sum(len(expected[g]) for g in missing) + sum(len(set(expected[g]) - set(reported[g])) for g in wrong),
        "errors": imported.get("errors", []), "warnings": imported.get("warningCount", 0), "seconds": imported.get("seconds"),
        "complete": not missing and not extra and not wrong and not imported.get("errors"),
        "failedLoudly": bool(imported.get("errors")),
    }


def percentile(values, pct):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round(pct / 100 * (len(ordered) - 1))))]


def main(dirs):
    totals = Counter()
    by_kind = defaultdict(Counter)
    causes = defaultdict(Counter)
    durations = []
    samples = defaultdict(list)
    imports = []
    stats = defaultdict(Counter)
    configs = {}

    for d in map(Path, dirs):
        for results in sorted(d.glob("results-*.jsonl")):
            for line in results.open():
                r = json.loads(line)
                phase = "dryrun" if r["dryRun"] else "mutations"
                totals[(phase, r["classification"])] += 1
                by_kind[r["kind"] + (" (DryRun)" if r["dryRun"] else "")][r["classification"]] += 1
                durations.append(r["ms"])
                if r["classification"] != "ok":
                    cause = failure_cause(r.get("audit") or r.get("scriptError"))
                    causes[r["classification"]][(r["kind"], cause)] += 1
                    if len(samples[(r["classification"], r["kind"])]) < 2:
                        samples[(r["classification"], r["kind"])].append(r)
        snapshots = {p.stem[len("snapshot-"):]: json.loads(p.read_text()) for p in d.glob("snapshot-*.json")}
        for p in sorted(d.glob("import-*.json")):
            label = p.stem[len("import-"):]
            data = json.loads(p.read_text())
            target = "initial" if label.startswith("pressure-") else label
            entry = {"dir": d.name, "label": label, "script": Path(data.get("script", "")).name}
            if target in snapshots:
                entry.update(compare_import(data, snapshots[target]))
            else:
                entry.update({"seconds": data.get("seconds"), "errors": data.get("errors", []), "warnings": data.get("warningCount", 0),
                              "reportedGroups": data.get("permissionCount")})
            imports.append(entry)
        for p in d.glob("stats-*.json"):
            data = json.loads(p.read_text())
            phase = p.stem[len("stats-"):]
            stats[phase].update(data.get("stats", {}))
            stats[phase]["elapsedSeconds"] += int(data.get("elapsedSeconds", 0))
            configs[d.name] = data.get("config")

    mutation_total = sum(v for (phase, _), v in totals.items() if phase == "mutations")
    dryrun_total = sum(v for (phase, _), v in totals.items() if phase == "dryrun")
    lines = ["# Dry run results", ""]
    if mutation_total or dryrun_total:
        lines += [f"**{mutation_total:,} mutations** and **{dryrun_total:,} HelloID DryRun operations** through the unmodified "
                  "`grantPermission.ps1` / `revokePermission.ps1`.", "",
                  "| Outcome | Mutations | DryRun |", "|---|---:|---:|"]
        for cls in ["ok", "silent_failure", "failed_but_applied", "reported_failure", "dryrun_wrote"]:
            lines.append(f"| {cls} | {totals[('mutations', cls)]:,} | {totals[('dryrun', cls)]:,} |")
        lines += ["", f"Script duration per operation: p50 {percentile(durations, 50)} ms, p95 {percentile(durations, 95)} ms, max {max(durations) if durations else None} ms.", ""]
        lines += ["## Outcome by operation type", "", "| Operation | ok | silent_failure | failed_but_applied | reported_failure | dryrun_wrote |", "|---|---:|---:|---:|---:|---:|"]
        for kind in sorted(by_kind):
            c = by_kind[kind]
            lines.append(f"| {kind} | {c['ok']:,} | {c['silent_failure']:,} | {c['failed_but_applied']:,} | {c['reported_failure']:,} | {c['dryrun_wrote']:,} |")
        lines += ["", "## Causes of non-ok outcomes", "", "| Outcome | Operation | Cause | Count |", "|---|---|---|---:|"]
        for cls, counter in causes.items():
            for (kind, cause), count in counter.most_common(25):
                lines.append(f"| {cls} | {kind} | {cause} | {count:,} |")
    if imports:
        lines += ["", "## Imports compared with the tenant's real state", "",
                  "| Run | Import | Script | Seconds | Groups expected | Reported | Missing groups | Wrong member sets | Missing memberships | Warnings | Errors | Result |",
                  "|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|"]
        for i in imports:
            if "complete" in i:
                result = "complete" if i["complete"] else ("failed loudly" if i["failedLoudly"] and not i["missingGroups"] else
                                                          ("**incomplete, failed loudly**" if i["failedLoudly"] else "**INCOMPLETE, reported success**"))
            else:
                result = "not compared (tenant changing)"
            lines.append(f"| {i['dir']} | {i['label']} | {i['script']} | {i.get('seconds')} | {i.get('expectedGroups', '')} | {i.get('reportedGroups', '')} | "
                         f"{i.get('missingGroups', '')} | {i.get('groupsWithWrongMembers', '')} | {i.get('missingMemberships', '')} | {i.get('warnings', '')} | {len(i.get('errors') or [])} | {result} |")
    if stats:
        lines += ["", "## Fake Graph counters", "", "| Phase | Seconds | Batch calls | Sub-requests | 429 (quota) | 429 (random) | 503 | Early retries | Adds | Removes | Intranet requests | Intranet throttled |",
                  "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
        for phase in sorted(stats):
            s = stats[phase]
            intranet = f"{s['intranet_throttled']:,} ({100 * s['intranet_throttled'] / s['intranet_requests']:.1f}%)" if s["intranet_requests"] else "0"
            lines.append(f"| {phase} | {s['elapsedSeconds']:,} | {s['batch_calls']:,} | {s['batch_subrequests']:,} | {s['throttled_bucket']:,} | {s['throttled_random']:,} | "
                         f"{s['transient_503']:,} | {s['early_retries']:,} | {s['writes_add']:,} | {s['writes_remove']:,} | {s['intranet_requests']:,} | {intranet} |")
        lines += ["", "Fake Graph configuration per run: " + json.dumps(configs)]
    if samples:
        lines += ["", "## Sample non-ok operations", ""]
        for (cls, kind), rows in sorted(samples.items()):
            for r in rows:
                lines.append(f"- `{cls}` / `{kind}`: success={r['success']} before={r['before']} after={r['after']} — {(r.get('audit') or r.get('scriptError') or '')[:300]}")

    report = "\n".join(lines)
    print(report)
    out = Path(dirs[0]).parent
    (out / "summary.md").write_text(report)
    (out / "summary.json").write_text(json.dumps({
        "totals": {f"{p}:{c}": v for (p, c), v in totals.items()}, "byKind": by_kind, "imports": imports,
        "stats": stats, "durationsMs": {"p50": percentile(durations, 50), "p95": percentile(durations, 95)},
    }, indent=2, default=list))


if __name__ == "__main__":
    main(sys.argv[1:])

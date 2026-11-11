#!/usr/bin/env python3
"""Splits ops.jsonl for one shard into per-worker JSON files. Workers own disjoint groups, so order per group is kept."""
import json
import sys
import uuid
from pathlib import Path

ops_file, shard, parts, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), Path(sys.argv[4])
buckets = {(phase, p): [] for phase in ("dryrun", "mutations") for p in range(parts)}
with open(ops_file) as f:
    for line in f:
        op = json.loads(line)
        if op["shard"] != shard:
            continue
        part = int(uuid.UUID(op["permissionId"]).hex[:8], 16) % parts
        buckets[("dryrun" if op["dryRun"] else "mutations", part)].append(op)
for (phase, part), ops in buckets.items():
    (out / f"ops-shard{shard}-{phase}-part{part}.json").write_text(json.dumps(ops))
    print(f"shard {shard} {phase} part {part}: {len(ops)} operations")

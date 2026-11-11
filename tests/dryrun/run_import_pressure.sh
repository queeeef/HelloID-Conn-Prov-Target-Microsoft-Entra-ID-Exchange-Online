#!/usr/bin/env bash
# Runs the 2.7.0 and the fixed importPermission.ps1 alternately against the same (unchanging) tenant
# under heavy throttling, and compares each result with the tenant's real memberships.
# Usage: run_import_pressure.sh <workdir> [rounds]
set -euo pipefail
work="${1:?work directory}"
rounds="${2:-3}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
here="$repo/tests/dryrun"
out="$work/out"
mkdir -p "$out"
fake() { curl -sS --fail ${2:+-X "$2"} "https://graph.microsoft.com/_fake/$1"; }

OPS=10 DRYRUN_OPS=0 bash "$here/setup_fake_graph.sh" "$work"
git -C "$repo" show "${BASELINE_REF:-fd3e2ca}:permissions/groups/importPermission.ps1" > "$work/importPermission-2.7.0.ps1"
fake snapshot > "$out/snapshot-initial.json"

for round in $(seq 1 "$rounds"); do
  for variant in 2.7.0 fixed; do
    script="$repo/permissions/groups/importPermission.ps1"
    [ "$variant" = "2.7.0" ] && script="$work/importPermission-2.7.0.ps1"
    sleep 15  # let the quota recover between runs
    pwsh -NoProfile -File "$here/Invoke-DryRunImport.ps1" -ScriptPath "$script" -OutFile "$out/import-pressure-${variant}-${round}.json" -Label "pressure-${variant}-${round}"
  done
done
fake stats > "$out/stats-pressure.json"
python3 "$here/analyze.py" "$out"

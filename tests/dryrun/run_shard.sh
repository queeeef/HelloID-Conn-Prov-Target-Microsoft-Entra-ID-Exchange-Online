#!/usr/bin/env bash
# Runs one shard of the dry run:
#   1. import, compared with the tenant                     (import-initial)
#   2. HelloID DryRun operations, which must not write      (results-*-dryrun-*)
#   3. mutations by PARTS parallel workers, while an import runs every IMPORT_INTERVAL seconds
#   4. import, compared with the tenant after all mutations (import-final)
# Usage: run_shard.sh <shard> <workdir>
set -euo pipefail
shard="${1:?shard}"
work="${2:?work directory}"
parts="${PARTS:-2}"
interval="${IMPORT_INTERVAL:-60}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
here="$repo/tests/dryrun"
out="$work/out"
mkdir -p "$out"

fake() { curl -sS --fail ${2:+-X "$2"} "https://graph.microsoft.com/_fake/$1"; }

bash "$here/setup_fake_graph.sh" "$work"
python3 "$here/split_ops.py" "$work/data/ops.jsonl" "$shard" "$parts" "$work/data"
cp "$work/generation.json" "$out/"

echo "::group::Initial import"
fake snapshot > "$out/snapshot-initial.json"
pwsh -NoProfile -File "$here/Invoke-DryRunImport.ps1" -ScriptPath "$repo/permissions/groups/importPermission.ps1" -OutFile "$out/import-initial.json" -Label initial
fake stats > "$out/stats-1-initial-import.json"; fake reset-stats POST > /dev/null
echo "::endgroup::"

run_workers() {
  local phase="$1" pids=() p
  for p in $(seq 0 $((parts - 1))); do
    pwsh -NoProfile -File "$here/Invoke-DryRunWorker.ps1" \
      -OpsFile "$work/data/ops-shard${shard}-${phase}-part${p}.json" -TenantFile "$work/data/tenant.json" \
      -ResultsFile "$out/results-shard${shard}-${phase}-part${p}.jsonl" -RepoRoot "$repo" &
    pids+=($!)
  done
  local failed=0
  for p in "${pids[@]}"; do wait "$p" || failed=1; done
  return $failed
}

echo "::group::HelloID DryRun operations"
run_workers dryrun
fake stats > "$out/stats-2-dryrun.json"; fake reset-stats POST > /dev/null
echo "::endgroup::"

echo "::group::Mutations with concurrent imports every ${interval}s"
rm -f "$work/mutations.done"
(
  n=0
  while [ ! -f "$work/mutations.done" ]; do
    for _ in $(seq 1 "$interval"); do [ -f "$work/mutations.done" ] && exit 0; sleep 1; done
    n=$((n + 1))
    pwsh -NoProfile -File "$here/Invoke-DryRunImport.ps1" -ScriptPath "$repo/permissions/groups/importPermission.ps1" \
      -OutFile "$out/import-concurrent-$(printf %02d $n).json" -Label "concurrent-$n" || true
  done
) &
import_loop=$!
run_workers mutations || echo "a worker exited with an error"
touch "$work/mutations.done"
wait "$import_loop" || true
fake stats > "$out/stats-3-mutations.json"; fake reset-stats POST > /dev/null
echo "::endgroup::"

echo "::group::Final import"
fake snapshot > "$out/snapshot-final.json"
pwsh -NoProfile -File "$here/Invoke-DryRunImport.ps1" -ScriptPath "$repo/permissions/groups/importPermission.ps1" -OutFile "$out/import-final.json" -Label final
fake stats > "$out/stats-4-final-import.json"
echo "::endgroup::"

python3 "$here/analyze.py" "$out"

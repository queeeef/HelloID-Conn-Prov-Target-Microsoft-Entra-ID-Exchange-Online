#!/usr/bin/env bash
# Generates the tenant, points graph.microsoft.com / login.microsoftonline.com at a local fake Graph
# server with a trusted certificate, and starts it. Needs sudo (CI runner only).
# Usage: setup_fake_graph.sh <workdir>   (FAKE_* environment variables configure throttling)
set -euo pipefail
work="${1:?work directory}"
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$work/data"

python3 "$here/generate_tenant.py" --out "$work/data" --ops "${OPS:-100000}" --dryrun-ops "${DRYRUN_OPS:-5000}" --shards "${SHARDS:-4}" > "$work/generation.json"
cat "$work/generation.json"

bash "$here/make_certs.sh" "$work/certs"
sudo cp "$work/certs/ca.crt" /usr/local/share/ca-certificates/helloid-dryrun-ca.crt
sudo update-ca-certificates > /dev/null
grep -q "graph.microsoft.com" /etc/hosts || echo "127.0.0.1 graph.microsoft.com login.microsoftonline.com" | sudo tee -a /etc/hosts > /dev/null

sudo env FAKE_PORT=443 FAKE_RATE="${FAKE_RATE:-250}" FAKE_BURST="${FAKE_BURST:-500}" FAKE_RANDOM_429="${FAKE_RANDOM_429:-0.003}" \
  FAKE_RANDOM_503="${FAKE_RANDOM_503:-0.002}" FAKE_INTRANET_RPS="${FAKE_INTRANET_RPS:-20}" FAKE_NONMEMBER_MESSAGE_ID="${FAKE_NONMEMBER_MESSAGE_ID:-member}" \
  python3 "$here/fake_graph.py" "$work/data/tenant.json" "$work/certs/server.crt" "$work/certs/server.key" > "$work/fake-graph.log" 2>&1 &
for i in $(seq 1 30); do
  if grep -q "listening" "$work/fake-graph.log" 2>/dev/null; then break; fi
  sleep 1
done
cat "$work/fake-graph.log"
FAKE_PORT=443 python3 "$here/smoke_test.py" "$work/certs/ca.crt" "$work/data/tenant.json"
curl -sS --fail -X POST https://graph.microsoft.com/_fake/reset-stats > /dev/null

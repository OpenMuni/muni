#!/usr/bin/env bash
# End-to-end smoke for the Muni MCP layer.
#
# The Cambridge MCP server is a thin wrapper around
# `bundle exec muni records ls <table> --json -y`. The actual MCP transport
# is owned by the host (Claude Desktop, Continue, etc.); here we exercise the
# data plane it depends on. If every command below prints `[OK]`, the server
# will return rows once a host runs it.
#
# Usage:
#   ./mcp/test_servers.sh             # uses existing data/db/muni.sqlite3
#   FRESH=1 ./mcp/test_servers.sh     # rebuilds + seeds Cambridge beats
set -euo pipefail

cd "$(dirname "$0")/.."

if [ "${FRESH:-0}" = "1" ]; then
  rm -f data/db/muni.sqlite3 data/db/muni.sqlite3-shm data/db/muni.sqlite3-wal
  bundle exec muni data migrate --json > /dev/null
  bundle exec muni beats seed --json > /dev/null
fi

check() {
  local label="$1"; shift
  local out
  if ! out=$(bundle exec muni "$@" --json -y 2>&1); then
    echo "[FAIL] $label -> $out"
    return 1
  fi
  if ! echo "$out" | python3 -c 'import sys, json; json.loads(sys.stdin.read())' >/dev/null 2>&1; then
    echo "[FAIL] $label produced non-JSON output: ${out:0:120}"
    return 1
  fi
  local n
  n=$(echo "$out" | python3 -c 'import sys, json; d=json.loads(sys.stdin.read()); print(len(d) if isinstance(d, list) else 1)')
  echo "[OK] $label rows=$n"
}

echo "== cambridge =="
check "cambridge_police_log"    records ls police_log_entrys --hall=cambridge --limit=5
check "cambridge_sr"            records ls service_requests  --hall=cambridge --limit=5
check "cambridge_permits"       records ls building_permits  --hall=cambridge --limit=5
check "cambridge_crashes"       records ls crashs            --hall=cambridge --limit=5
check "cambridge_trees"         records ls trees             --hall=cambridge --limit=5
check "cambridge_digest_context" analytics digest-context     --hall=cambridge

digest_context=$(bundle exec muni analytics digest-context --hall=cambridge --json -y)
echo "$digest_context" | python3 -c '
import json, sys
payload = json.loads(sys.stdin.read())
missing = [key for key in ("source_items", "ranked_candidates", "source_freshness") if key not in payload]
if missing:
    raise SystemExit(f"Digest context missing fields: {missing}")
if "old markdown digest" in json.dumps(payload).lower():
    raise SystemExit("Digest context leaked old digest prose")
'

echo "OK"

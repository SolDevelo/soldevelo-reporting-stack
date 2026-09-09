#!/usr/bin/env bash
# =============================================================================
# Verify Superset is healthy, assets are imported, and dashboard exists.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

SUPERSET_HOST="${SUPERSET_HOST_EXTERNAL:-localhost}"
SUPERSET_PORT="${SUPERSET_PORT:-8088}"
SUPERSET_USER="${SUPERSET_ADMIN_USER:-admin}"
SUPERSET_PASS="${SUPERSET_ADMIN_PASSWORD:-changeme}"

PASS=0
FAIL=0

check() {
  local name="$1"
  local cmd="$2"
  if eval "$cmd" > /dev/null 2>&1; then
    echo "  PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "Verify: Superset"
echo "-------------------------------"

check "Superset health endpoint" \
  "curl -sf http://${SUPERSET_HOST}:${SUPERSET_PORT}/health"

# Get an access token via the Superset security API
get_token() {
  local payload
  payload=$(python3 -c "import json,sys; print(json.dumps({'username':sys.argv[1],'password':sys.argv[2],'provider':'db','refresh':True}))" "$SUPERSET_USER" "$SUPERSET_PASS")
  curl -sf -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "http://${SUPERSET_HOST}:${SUPERSET_PORT}/api/v1/security/login" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

TOKEN=$(get_token 2>/dev/null || echo "")

if [ -z "$TOKEN" ]; then
  echo "  FAIL  Superset API authentication"
  FAIL=$((FAIL + 1))
else
  echo "  PASS  Superset API authentication"
  PASS=$((PASS + 1))

  AUTH_HEADER="Authorization: Bearer $TOKEN"

  check "At least one database registered" \
    "curl -sf -H '$AUTH_HEADER' http://${SUPERSET_HOST}:${SUPERSET_PORT}/api/v1/database/ | python3 -c \"import sys,json; assert json.load(sys.stdin)['count']>0\""

  check "At least one dataset registered" \
    "curl -sf -H '$AUTH_HEADER' http://${SUPERSET_HOST}:${SUPERSET_PORT}/api/v1/dataset/ | python3 -c \"import sys,json; assert json.load(sys.stdin)['count']>0\""

  check "At least one chart registered" \
    "curl -sf -H '$AUTH_HEADER' http://${SUPERSET_HOST}:${SUPERSET_PORT}/api/v1/chart/ | python3 -c \"import sys,json; assert json.load(sys.stdin)['count']>0\""

  check "Dashboard 'OLMIS Requisition Overview' exists" \
    "curl -sf -H '$AUTH_HEADER' http://${SUPERSET_HOST}:${SUPERSET_PORT}/api/v1/dashboard/ | python3 -c \"import sys,json; titles=[d['dashboard_title'] for d in json.load(sys.stdin)['result']]; assert 'OLMIS Requisition Overview' in titles, titles\""

  # Charts attached to a dashboard that its layout does not place. The asset
  # importer only ever adds, so a chart deleted from the YAML, or moved off a
  # dashboard, keeps its attachment - and Superset appends anything attached but
  # unplaced to the bottom of the dashboard. It renders as a stray chart with no
  # error anywhere, which is exactly how it gets found: by someone asking why it
  # is there. The layout in the YAML is authoritative, so a mismatch is always
  # stale attachment left behind by an earlier deploy.
  # position_json carries the real slice ids in chartId once the importer has
  # remapped them, so the two sets are directly comparable.
  read -r -d '' ORPHAN_PY <<'PYEOF' || true
import json, os, re, sys, urllib.request
base = "http://%s:%s/api/v1" % (os.environ["SUPERSET_HOST"], os.environ["SUPERSET_PORT"])
def get(u):
    req = urllib.request.Request(base + u, headers={"Authorization": "Bearer " + os.environ["SS_TOKEN"]})
    return json.load(urllib.request.urlopen(req))
stray = []
for d in get("/dashboard/?q=(page_size:100)")["result"]:
    detail = get("/dashboard/%s" % d["id"])["result"]
    placed = set(int(x) for x in re.findall(r'"chartId":\s*(\d+)', detail.get("position_json") or ""))
    for c in get("/dashboard/%s/charts" % d["id"])["result"]:
        if c["id"] not in placed:
            stray.append("%s :: %s" % (d["dashboard_title"], c.get("slice_name")))
if stray:
    sys.stderr.write("stale chart attachments, not placed by any dashboard layout:\n")
    for x in stray:
        sys.stderr.write("          " + x + "\n")
    sys.stderr.write("        detach them, or delete the chart if no YAML declares it any more\n")
    sys.exit(1)
PYEOF
  # not run through check(), which sends both streams to /dev/null: the whole
  # point of this one is the list of names it prints
  if ORPHANS=$(SS_TOKEN="$TOKEN" SUPERSET_HOST="$SUPERSET_HOST" SUPERSET_PORT="$SUPERSET_PORT" \
       python3 -c "$ORPHAN_PY" 2>&1); then
    echo "  PASS  No chart attached to a dashboard that does not lay it out"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  No chart attached to a dashboard that does not lay it out"
    echo "$ORPHANS" | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  fi
fi

echo "-------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

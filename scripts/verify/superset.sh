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
fi

echo "-------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

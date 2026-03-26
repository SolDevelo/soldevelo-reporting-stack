#!/usr/bin/env bash
# =============================================================================
# Verify analytics packages: validate extensions, build dbt, check marts,
# import Superset assets, and verify dashboards.
#
# This runs the full package pipeline in local mode using the built-in
# OLMIS example packages.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

# Use the example packages
export ANALYTICS_CORE_PATH="${ANALYTICS_CORE_PATH:-examples/olmis-analytics-core}"
export ANALYTICS_EXTENSIONS_PATHS="${ANALYTICS_EXTENSIONS_PATHS:-examples/olmis-analytics-malawi}"

CLICKHOUSE_HOST="${CLICKHOUSE_HOST_EXTERNAL:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-changeme}"
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

echo "Verify: analytics packages (core + extensions)"
echo "-------------------------------"
echo "Core: $ANALYTICS_CORE_PATH"
echo "Extensions: $ANALYTICS_EXTENSIONS_PATHS"
echo ""

# Step 1: Validate extension packages
echo "--- Validating extensions ---"
bash "$REPO_ROOT/scripts/packages/validate.sh"
echo ""

# Step 2: Build dbt (core + extensions)
echo "--- Building dbt models ---"
bash "$REPO_ROOT/scripts/dbt/build.sh"
echo ""

# Step 3: Check extension mart exists and has data
echo "--- Checking extension marts ---"
check "curated.mart_malawi_requisition_by_region exists and has rows" \
  "curl -sf 'http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/' --user '${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}' --data-binary 'SELECT count() FROM curated.mart_malawi_requisition_by_region' | grep -v '^0$'"

# Step 4: Import Superset assets (core + extensions)
echo ""
echo "--- Importing Superset assets ---"
bash "$REPO_ROOT/scripts/superset/import-all.sh"
echo ""

# Step 5: Check extension dashboard exists
echo "--- Checking Superset dashboards ---"
TOKEN=$(python3 -c "import json,sys; print(json.dumps({'username':sys.argv[1],'password':sys.argv[2],'provider':'db','refresh':True}))" "$SUPERSET_USER" "$SUPERSET_PASS" | \
  curl -sf -X POST -H "Content-Type: application/json" -d @- \
    "http://${SUPERSET_HOST}:${SUPERSET_PORT}/api/v1/security/login" | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")

if [ -n "$TOKEN" ]; then
  AUTH_HEADER="Authorization: Bearer $TOKEN"

  check "Dashboard 'OLMIS Requisition Overview' exists" \
    "curl -sf -H '$AUTH_HEADER' http://${SUPERSET_HOST}:${SUPERSET_PORT}/api/v1/dashboard/ | python3 -c \"import sys,json; titles=[d['dashboard_title'] for d in json.load(sys.stdin)['result']]; assert 'OLMIS Requisition Overview' in titles\""

  check "Dashboard 'Malawi Regional Overview' exists" \
    "curl -sf -H '$AUTH_HEADER' http://${SUPERSET_HOST}:${SUPERSET_PORT}/api/v1/dashboard/ | python3 -c \"import sys,json; titles=[d['dashboard_title'] for d in json.load(sys.stdin)['result']]; assert 'Malawi Regional Overview' in titles\""
else
  echo "  FAIL  Superset API authentication"
  FAIL=$((FAIL + 2))
fi

echo ""
echo "-------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

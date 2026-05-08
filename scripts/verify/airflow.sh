#!/usr/bin/env bash
# =============================================================================
# Verify Airflow is healthy and the platform_refresh DAG is registered.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

AIRFLOW_HOST="${AIRFLOW_HOST_EXTERNAL:-localhost}"
AIRFLOW_PORT="${AIRFLOW_PORT:-8080}"
AIRFLOW_USER="${AIRFLOW_ADMIN_USER:-admin}"
AIRFLOW_PASS="${AIRFLOW_ADMIN_PASSWORD:-admin}"

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

AIRFLOW_BASE="http://${AIRFLOW_HOST}:${AIRFLOW_PORT}"

echo "Verify: Airflow orchestration"
echo "-------------------------------"

check "Airflow webserver health" \
  "curl -sf ${AIRFLOW_BASE}/api/v2/monitor/health"

check "Airflow scheduler healthy" \
  "curl -sf ${AIRFLOW_BASE}/api/v2/monitor/health | python3 -c \"import sys,json; d=json.load(sys.stdin); assert d['scheduler']['status']=='healthy'\""

# Airflow 3.x uses JWT (issued by the auth manager) instead of HTTP basic auth.
TOKEN=$(curl -sf -X POST "${AIRFLOW_BASE}/auth/token" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"${AIRFLOW_USER}\",\"password\":\"${AIRFLOW_PASS}\"}" \
  2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || true)

check "DAG 'platform_refresh' registered" \
  "[ -n '${TOKEN}' ] && curl -sf -H 'Authorization: Bearer ${TOKEN}' ${AIRFLOW_BASE}/api/v2/dags/platform_refresh"

echo "-------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

#!/usr/bin/env bash
# =============================================================================
# Verify Airflow is healthy and the platform_refresh DAG is registered.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

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

echo "Verify: Airflow orchestration"
echo "-------------------------------"

check "Airflow webserver health" \
  "curl -sf http://localhost:${AIRFLOW_PORT}/health"

check "Airflow scheduler healthy" \
  "curl -sf http://localhost:${AIRFLOW_PORT}/health | python3 -c \"import sys,json; d=json.load(sys.stdin); assert d['scheduler']['status']=='healthy'\""

check "DAG 'platform_refresh' registered" \
  "curl -sf -u '${AIRFLOW_USER}:${AIRFLOW_PASS}' http://localhost:${AIRFLOW_PORT}/api/v1/dags/platform_refresh"

echo "-------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

#!/usr/bin/env bash
# =============================================================================
# Verify dbt transformations.
# Runs dbt build and checks that curated mart tables exist with data.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

CLICKHOUSE_HOST="${CLICKHOUSE_HOST_EXTERNAL:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
CLICKHOUSE_USER="${CLICKHOUSE_USER:-default}"
CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-changeme}"

PASS=0
FAIL=0

ch_query() {
  curl -sf "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/" \
    --user "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" \
    --data-binary "$1" 2>/dev/null
}

echo "Verify: dbt transformations"
echo "-------------------------------"

echo ""
echo "Running dbt build..."
DBT_LOG=$(mktemp)
if bash "$REPO_ROOT/scripts/dbt/build.sh" > "$DBT_LOG" 2>&1; then
  echo "  PASS  dbt build succeeded"
  PASS=$((PASS + 1))
else
  echo "  FAIL  dbt build failed:"
  echo ""
  cat "$DBT_LOG"
  echo ""
  FAIL=$((FAIL + 1))
fi
rm -f "$DBT_LOG"

echo ""
echo "Checking curated mart tables..."

# Check mart tables exist and have rows
MART_TABLES=$(ch_query "SELECT name FROM system.tables WHERE database = 'curated' AND name LIKE 'mart_%' ORDER BY name" 2>/dev/null)
if [ -z "$MART_TABLES" ]; then
  echo "  FAIL  No mart tables found in curated database"
  FAIL=$((FAIL + 1))
else
  while IFS= read -r table; do
    row_count=$(ch_query "SELECT count() FROM curated.${table}" 2>/dev/null || echo "0")
    if [ "$row_count" -gt 0 ] 2>/dev/null; then
      echo "  PASS  curated.${table} has ${row_count} rows"
      PASS=$((PASS + 1))
    else
      echo "  FAIL  curated.${table} has 0 rows"
      FAIL=$((FAIL + 1))
    fi
  done <<< "$MART_TABLES"
fi

echo "-------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

#!/usr/bin/env bash
# =============================================================================
# Verify ClickHouse raw landing ingestion.
# Checks that events tables exist and that ingestion is producing data. Empty
# tables are tolerated (the initial snapshot loads large tables last); only a
# total absence of data is a failure.
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
WARN=0

ch_query() {
  curl -sf "http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}/" \
    --user "${CLICKHOUSE_USER}:${CLICKHOUSE_PASSWORD}" \
    --data-binary "$1" 2>/dev/null
}

check() {
  local name="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "  PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL  $name"
    FAIL=$((FAIL + 1))
  fi
}

echo "ClickHouse raw landing verification"
echo "------------------------------------"

# Check databases exist
check "Database 'raw' exists" \
  test "$(ch_query "SELECT 1 FROM system.databases WHERE name = 'raw'")" = "1"

check "Database 'curated' exists" \
  test "$(ch_query "SELECT 1 FROM system.databases WHERE name = 'curated'")" = "1"

# Check events tables exist and have rows.
# An empty table is EXPECTED while the initial snapshot is still loading (large
# tables land last), so an empty table is a WARN, not a failure. Only a total
# absence of data means ingestion is actually broken.
EVENTS_TABLES=$(ch_query "SELECT name FROM system.tables WHERE database = 'raw' AND name LIKE 'events_%' ORDER BY name" 2>/dev/null)
if [ -z "$EVENTS_TABLES" ]; then
  echo "  FAIL  No events tables found in raw database"
  FAIL=$((FAIL + 1))
else
  tables_with_data=0
  while IFS= read -r table; do
    row_count=$(ch_query "SELECT count() FROM raw.${table}" 2>/dev/null || echo "0")
    if [ "$row_count" -gt 0 ] 2>/dev/null; then
      echo "  PASS  raw.${table} has ${row_count} rows"
      PASS=$((PASS + 1))
      tables_with_data=$((tables_with_data + 1))
    else
      echo "  WARN  raw.${table} has 0 rows (not yet ingested — initial snapshot may still be running)"
      WARN=$((WARN + 1))
    fi
  done <<< "$EVENTS_TABLES"

  # Empty tables mid-snapshot are fine; no data at all is a real ingestion failure.
  if [ "$tables_with_data" -eq 0 ]; then
    echo "  FAIL  no raw events table has any rows — ingestion is not working"
    FAIL=$((FAIL + 1))
  fi
fi

echo "------------------------------------"
echo "Results: ${PASS} passed, ${FAIL} failed, ${WARN} warning(s)"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

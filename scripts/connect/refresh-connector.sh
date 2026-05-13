#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Refresh the CDC connector after a configuration change.
#
# Common scenario: you've added tables to the publication and to
# SOURCE_PG_TABLE_ALLOWLIST in .env, and now want them backfilled into
# ClickHouse without disturbing tables that are already being captured.
#
# Modes (MODE env var, default: auto):
#
#   auto         Read the connector's current config, diff against the
#                desired allowlist from .env, re-register, and trigger an
#                INCREMENTAL snapshot for tables that are new. Existing
#                tables keep their offsets — no disruption. This is the
#                recommended path. Requires the signal table to exist
#                (created by reporting-stack init SQL).
#
#   incremental  Skip diffing; trigger an incremental snapshot for the
#                explicit TABLES=schema.t1,schema.t2 list. Use this when
#                you know exactly which tables to backfill (e.g., after a
#                schema change to a single table).
#
#   reset        Full offset reset + delete + re-register, which causes
#                Debezium to re-snapshot every captured table. This is the
#                pre-incremental-snapshot fallback; slow on large
#                deployments (re-reads existing tables) but always works,
#                even if the signal table is missing.
#
# Usage:
#   make connector-refresh                                  # auto mode
#   MODE=incremental TABLES=schema.t1 make connector-refresh
#   MODE=reset make connector-refresh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

CONNECT_PORT="${CONNECT_PORT:-8083}"
CONNECT_URL="http://localhost:${CONNECT_PORT}"
CONNECTOR_NAME="openlmis-postgres-cdc"
MODE="${MODE:-auto}"
SIGNAL_TABLE="public.debezium_signal"

case "$MODE" in
  auto|incremental|reset) ;;
  *)
    echo "ERROR: unknown MODE '$MODE' — expected auto, incremental, or reset" >&2
    exit 2
    ;;
esac

echo "=== Refreshing CDC connector (mode: $MODE) ==="
echo ""

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

connector_exists() {
  curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" > /dev/null 2>&1
}

# Returns the connector's currently-configured table.include.list (comma-separated).
# Empty string if the connector doesn't exist or the field is missing.
#
# NOTE: an empty return causes `diff_lists` to treat every desired table as
# "new" and incrementally snapshot all of them on the next auto refresh. This
# can happen if /config returns degraded JSON (rare). The redundant work is
# benign — Debezium and dbt staging both deduplicate — but the load surprise
# on large deployments is worth knowing about. Worst case: pass MODE=reset
# or MODE=incremental TABLES=... explicitly to bypass.
get_current_allowlist() {
  curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME/config" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('table.include.list',''))" \
    2>/dev/null || echo ""
}

# Diff two comma-separated lists. Prints elements in $1 but not in $2.
# Ignores the signal table (it's auto-managed and not a data table).
diff_lists() {
  local desired="$1"
  local current="$2"
  python3 - "$desired" "$current" "$SIGNAL_TABLE" <<'PY'
import sys
desired = {t.strip() for t in sys.argv[1].split(',') if t.strip()}
current = {t.strip() for t in sys.argv[2].split(',') if t.strip()}
signal = sys.argv[3]
new = sorted(desired - current - {signal})
print(",".join(new))
PY
}

# -----------------------------------------------------------------------------
# Mode: reset (full offset reset, original behavior)
# -----------------------------------------------------------------------------
if [ "$MODE" = "reset" ]; then
  if ! connector_exists; then
    echo "Connector '$CONNECTOR_NAME' not found. Run 'make register-connector' for first-time setup."
    exit 1
  fi

  echo "Stopping connector..."
  curl -sf -X PUT "$CONNECT_URL/connectors/$CONNECTOR_NAME/stop" > /dev/null
  sleep 2

  echo "Resetting connector offsets..."
  curl -sf -X DELETE "$CONNECT_URL/connectors/$CONNECTOR_NAME/offsets" > /dev/null 2>&1 || {
    echo "WARNING: Offset reset failed (Connect may not support it). Falling back to delete + recreate."
  }
  sleep 1

  echo "Deleting connector..."
  curl -sf -X DELETE "$CONNECT_URL/connectors/$CONNECTOR_NAME" > /dev/null
  sleep 2

  echo "Re-registering connector (triggers full re-snapshot)..."
  bash "$SCRIPT_DIR/register-connector.sh"

  echo ""
  echo "Re-initializing ClickHouse raw landing..."
  bash "$REPO_ROOT/scripts/clickhouse/init.sh"

  echo ""
  echo "Waiting 30s for snapshot to start..."
  sleep 30

  echo ""
  echo "Verifying ingestion..."
  bash "$REPO_ROOT/scripts/verify/ingestion.sh"

  echo ""
  echo "=== Connector refresh complete (mode: reset) ==="
  echo "Note: 'reset' mode re-snapshots every captured table. For future"
  echo "      table additions, prefer MODE=auto or MODE=incremental."
  exit 0
fi

# -----------------------------------------------------------------------------
# Mode: incremental (explicit TABLES list)
# -----------------------------------------------------------------------------
if [ "$MODE" = "incremental" ]; then
  TABLES="${TABLES:-}"
  if [ -z "$TABLES" ]; then
    echo "ERROR: MODE=incremental requires TABLES=schema.t1,schema.t2" >&2
    exit 2
  fi
  echo "Re-registering connector with current .env allowlist..."
  bash "$SCRIPT_DIR/register-connector.sh"
  echo ""
  echo "Re-initializing ClickHouse raw landing (creates tables for new topics)..."
  bash "$REPO_ROOT/scripts/clickhouse/init.sh"
  echo ""
  echo "Triggering incremental snapshot for: $TABLES"
  TABLES="$TABLES" bash "$SCRIPT_DIR/snapshot-tables.sh"
  echo ""
  echo "=== Connector refresh complete (mode: incremental) ==="
  exit 0
fi

# -----------------------------------------------------------------------------
# Mode: auto (diff against current config, snapshot only what's new)
# -----------------------------------------------------------------------------
if ! connector_exists; then
  echo "Connector '$CONNECTOR_NAME' not found — running first-time registration."
  bash "$SCRIPT_DIR/register-connector.sh"
  echo ""
  echo "Re-initializing ClickHouse raw landing..."
  bash "$REPO_ROOT/scripts/clickhouse/init.sh"
  echo ""
  echo "First-time registration triggers Debezium's built-in initial snapshot"
  echo "for every captured table. No incremental snapshot needed."
  echo ""
  echo "=== Connector refresh complete (mode: auto, first-time) ==="
  exit 0
fi

DESIRED="${SOURCE_PG_TABLE_ALLOWLIST:?SOURCE_PG_TABLE_ALLOWLIST not set in .env}"
CURRENT="$(get_current_allowlist)"
NEW_TABLES="$(diff_lists "$DESIRED" "$CURRENT")"

echo "Desired allowlist: $DESIRED"
echo "Current allowlist: $CURRENT"
echo "New tables:        ${NEW_TABLES:-<none>}"
echo ""

echo "Re-registering connector with desired allowlist..."
bash "$SCRIPT_DIR/register-connector.sh"
echo ""
echo "Re-initializing ClickHouse raw landing (creates tables for new topics)..."
bash "$REPO_ROOT/scripts/clickhouse/init.sh"
echo ""

if [ -z "$NEW_TABLES" ]; then
  echo "No new tables detected — connector config refreshed only."
  echo "If you expected an incremental snapshot, ensure new tables are in"
  echo "SOURCE_PG_TABLE_ALLOWLIST and in the publication, then retry."
  echo ""
  echo "=== Connector refresh complete (mode: auto, no new tables) ==="
  exit 0
fi

echo "Triggering incremental snapshot for new tables: $NEW_TABLES"
TABLES="$NEW_TABLES" bash "$SCRIPT_DIR/snapshot-tables.sh"

echo ""
echo "=== Connector refresh complete (mode: auto) ==="
echo "Next steps:"
echo "  - Monitor snapshot progress: make connector-status"
echo "  - Verify data lands:         make verify-ingestion"
echo "  - Rebuild marts when done:   make dbt-build"

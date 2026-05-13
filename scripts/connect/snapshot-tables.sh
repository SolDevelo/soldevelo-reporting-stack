#!/usr/bin/env bash
# =============================================================================
# Trigger a Debezium incremental snapshot for one or more tables.
#
# Use this after adding tables to the CDC allowlist (and re-registering the
# connector) to backfill the new tables' existing rows into ClickHouse without
# resetting all connector offsets or re-snapshotting tables already captured.
#
# Mechanism: inserts a signal row into public.debezium_signal in the source
# database. Debezium reads the row via its source signal channel and runs a
# chunk-by-chunk incremental snapshot alongside the live CDC stream — no
# connector restart, no offset reset, no disruption to ongoing change capture.
#
# Usage:
#   ./scripts/connect/snapshot-tables.sh TABLES=schema.table1,schema.table2
#   TABLES=referencedata.facility_operators ./scripts/connect/snapshot-tables.sh
#
# Optional env vars:
#   SIGNAL_ID         override the signal row ID (default: snapshot-<epoch>-<short-uuid>)
#   WAIT_SECS         seconds to wait for the connector to consume the signal (default: 60)
#                     set to 0 to skip the wait/verify step
#   POSTGRES_IMAGE    image used for the one-shot psql container (default: postgres:17-alpine)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

# --- Parse arguments ---------------------------------------------------------
# Accept TABLES=... as a positional argument for the make-target ergonomics
# (`make snapshot-tables TABLES=...` passes TABLES via env, but
# `./snapshot-tables.sh TABLES=...` is convenient for ad-hoc invocation).
for arg in "$@"; do
  case "$arg" in
    TABLES=*) TABLES="${arg#TABLES=}" ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

TABLES="${TABLES:-}"
if [ -z "$TABLES" ]; then
  cat >&2 <<EOF
ERROR: TABLES is required.

Usage:
  make snapshot-tables TABLES=schema.table1,schema.table2
  ./scripts/connect/snapshot-tables.sh TABLES=schema.table1,schema.table2

Each table must use the schema.table format and exist in the publication
(see ../mw-distro/reporting-stack/init-db.sql or equivalent).
EOF
  exit 2
fi

# Validate table format (schema.table, comma-separated) and build JSON array.
IFS=',' read -ra TABLE_ARR <<< "$TABLES"
TABLES_JSON="["
for i in "${!TABLE_ARR[@]}"; do
  t="$(echo "${TABLE_ARR[$i]}" | xargs)"  # trim whitespace
  if [[ ! "$t" =~ ^[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
    echo "ERROR: invalid table name '$t' — expected schema.table format" >&2
    exit 2
  fi
  [ "$i" -gt 0 ] && TABLES_JSON+=","
  TABLES_JSON+="\"$t\""
done
TABLES_JSON+="]"

# --- Defaults ----------------------------------------------------------------
SOURCE_PG_HOST="${SOURCE_PG_HOST:?SOURCE_PG_HOST not set — source .env first}"
SOURCE_PG_PORT="${SOURCE_PG_PORT:-5432}"
SOURCE_PG_DB="${SOURCE_PG_DB:?SOURCE_PG_DB not set}"
SOURCE_PG_USER="${SOURCE_PG_USER:?SOURCE_PG_USER not set}"
SOURCE_PG_PASSWORD="${SOURCE_PG_PASSWORD:?SOURCE_PG_PASSWORD not set}"
CONNECT_PORT="${CONNECT_PORT:-8083}"
CONNECT_URL="http://localhost:${CONNECT_PORT}"
CONNECTOR_NAME="openlmis-postgres-cdc"
WAIT_SECS="${WAIT_SECS:-60}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}"

# Generate a unique signal ID — Debezium uses this as the row PK.
if [ -z "${SIGNAL_ID:-}" ]; then
  SHORT_UUID="$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  SIGNAL_ID="snapshot-$(date +%s)-${SHORT_UUID}"
fi

echo "=== Triggering Debezium incremental snapshot ==="
echo "Tables:    $TABLES_JSON"
echo "Signal ID: $SIGNAL_ID"
echo ""

# --- Preflight: connector must exist and be RUNNING --------------------------
echo "Checking connector state..."
STATUS_JSON=$(curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" 2>&1) || {
  echo "ERROR: connector '$CONNECTOR_NAME' not found or Connect unreachable at $CONNECT_URL" >&2
  echo "       Run 'make register-connector' first." >&2
  exit 1
}
CONNECTOR_STATE=$(echo "$STATUS_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['connector']['state'])")
if [ "$CONNECTOR_STATE" != "RUNNING" ]; then
  echo "ERROR: connector is in state '$CONNECTOR_STATE' — must be RUNNING to receive signals." >&2
  echo "       Try 'make recover' to restore the pipeline, then retry." >&2
  exit 1
fi
echo "  Connector state: RUNNING ✓"

# --- Preflight: signal table must exist --------------------------------------
# Networking note: when running inside the kafka-connect / reporting-shared
# network, SOURCE_PG_HOST resolves to the source DB (e.g., olmis-db). We re-use
# that network for the one-shot psql container.
PSQL_NETWORK="reporting-shared"

run_psql() {
  local sql="$1"
  docker run --rm -i \
    --network "$PSQL_NETWORK" \
    -e PGPASSWORD="$SOURCE_PG_PASSWORD" \
    "$POSTGRES_IMAGE" \
    psql --host="$SOURCE_PG_HOST" --port="$SOURCE_PG_PORT" \
         --username="$SOURCE_PG_USER" --dbname="$SOURCE_PG_DB" \
         --no-psqlrc --tuples-only --no-align --quiet \
         --set=ON_ERROR_STOP=1 \
         -c "$sql"
}

echo "Checking signal table public.debezium_signal exists..."
if ! SIGNAL_EXISTS=$(run_psql "SELECT to_regclass('public.debezium_signal') IS NOT NULL"); then
  echo "ERROR: failed to query source database. Check credentials and network." >&2
  exit 1
fi
if [ "$(echo "$SIGNAL_EXISTS" | tr -d '[:space:]')" != "t" ]; then
  cat >&2 <<EOF
ERROR: public.debezium_signal does not exist in source database.

This table is created by the reporting-stack init SQL. To fix:
  1. Re-run the source DB init (e.g., restart mw-distro with the reporting overlay,
     or run the init SQL manually against your source database).
  2. Confirm the table exists, then retry.

Until the signal table exists, fall back to 'make connector-refresh MODE=reset'
(full offset reset; slower, re-snapshots every table).
EOF
  exit 1
fi
echo "  Signal table exists ✓"

# --- Insert signal row -------------------------------------------------------
# The 'data' column carries a JSON payload telling Debezium what to snapshot.
# Format per Debezium 3.x docs:
#   {"data-collections": ["<schema>.<table>", ...], "type": "incremental"}
SIGNAL_DATA="{\"data-collections\":${TABLES_JSON},\"type\":\"incremental\"}"

# SAFETY: SIGNAL_ID is built from `date +%s` plus /dev/urandom hex (no quotes
# possible); SIGNAL_DATA is built from TABLES_JSON which contains only entries
# matching ^[a-zA-Z_][a-zA-Z0-9_]*\.[a-zA-Z_][a-zA-Z0-9_]*$ (validated above).
# Neither value can contain a single quote, so inline interpolation into the
# SQL string literal is safe. If new payload fields are added that accept
# free-form text (descriptions, filters), switch to psql variable substitution
# or a heredoc before reusing this pattern.
echo "Inserting signal row..."
run_psql "INSERT INTO public.debezium_signal (id, type, data) VALUES ('$SIGNAL_ID', 'execute-snapshot', '$SIGNAL_DATA')" \
  > /dev/null
echo "  Signal inserted ✓"

# --- Wait for the connector to consume the signal ----------------------------
# Debezium reads the row through the WAL like any other insert; consumption
# typically happens within a few seconds. We don't try to confirm completion
# here (incremental snapshots can take minutes for large tables) — only that
# the signal was picked up. Completion is observable in connector logs and
# eventually in ClickHouse row counts.
if [ "$WAIT_SECS" -eq 0 ]; then
  echo ""
  echo "Skipping wait (WAIT_SECS=0). Check connector logs for snapshot progress:"
  echo "  docker compose -f compose/docker-compose.yml logs -f kafka-connect | grep -i 'incremental snapshot'"
  exit 0
fi

echo ""
echo "Waiting up to ${WAIT_SECS}s for the connector to consume the signal..."

# Debezium 3.x writes snapshot-window-open / snapshot-window-close rows into
# the signal table once it begins processing an incremental snapshot. We poll
# for those rows as proof that the connector saw and acted on our signal.
DEADLINE=$(( $(date +%s) + WAIT_SECS ))
CONSUMED=0
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 3

  # Bail out fast if the connector task has failed since we sent the signal.
  TASK_TRACE=$(curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['tasks'][0].get('trace',''))" 2>/dev/null || echo "")
  if echo "$TASK_TRACE" | grep -qi "fail\|error"; then
    echo ""
    echo "ERROR: connector task failed while consuming signal:" >&2
    echo "$TASK_TRACE" >&2
    exit 1
  fi

  # Check for snapshot-window-* markers (proof of consumption).
  WINDOW_COUNT=$(run_psql "SELECT count(*) FROM public.debezium_signal WHERE type LIKE 'snapshot-window-%'" \
    | tr -d '[:space:]')
  if [ "${WINDOW_COUNT:-0}" -gt 0 ]; then
    CONSUMED=1
    break
  fi
  printf "."
done
echo ""

if [ "$CONSUMED" -ne 1 ]; then
  echo ""
  echo "WARNING: timed out after ${WAIT_SECS}s without observing signal consumption." >&2
  echo "         The signal row is still in public.debezium_signal. Common causes:" >&2
  echo "           - Connector is busy catching up on backlog (large tables, just restarted)" >&2
  echo "           - signal.data.collection in the connector config doesn't match this table" >&2
  echo "             (current expected value: public.debezium_signal)" >&2
  echo "           - Signal table not in publication or table.include.list" >&2
  echo "         Inspect connector logs:" >&2
  echo "           make logs SVC=kafka-connect | grep -iE 'signal|snapshot'" >&2
  exit 1
fi

echo ""
echo "Signal accepted ✓ — Debezium has started processing it."
echo "(snapshot-window markers appear at the first chunk boundary, not at"
echo " snapshot completion — large tables may still be replicating in chunks)"
echo ""
echo "=== Snapshot signal dispatched ==="
echo ""
echo "Next steps:"
echo "  1. Watch progress in connector logs:"
echo "       docker compose -f compose/docker-compose.yml logs -f kafka-connect | grep -i 'snapshot'"
echo "  2. Verify rows arrive in ClickHouse:"
echo "       make verify-ingestion"
echo "  3. Once snapshot completes, rebuild marts:"
echo "       make dbt-build"

#!/usr/bin/env bash
# =============================================================================
# Recover from a PostgreSQL logical replication slot invalidation.
#
# When the reporting stack is down long enough for the source DB to exceed
# `max_slot_wal_keep_size`, PostgreSQL invalidates the replication slot to
# protect disk. The CDC stream has a gap — some changes are not in WAL
# anymore — and Debezium can't resume from the last offset. The source DB
# still has the correct *current* state; we just need to rebuild the
# baseline by snapshotting the configured tables and starting CDC from a
# fresh slot.
#
# What this script does:
#   1. Query pg_replication_slots; refuse to run if the slot is healthy
#      (use FORCE=1 to override).
#   2. Print a destructive-action preamble and require explicit confirmation
#      ("yes" on stdin, or FORCE=1 to skip).
#   3. Stop and delete the Kafka Connect connector. The DELETE /offsets call
#      clears stored offsets when possible; snapshot.mode=when_needed in the
#      connector config also handles any stale-offset cases that survive.
#   4. Drop the orphan replication slot in PostgreSQL.
#   5. Re-register the connector (Debezium creates a new slot + initial
#      snapshot of every table in table.include.list).
#   6. Re-initialize ClickHouse raw landing (idempotent; ensures Kafka-engine
#      tables exist for every topic).
#   7. Wait for the slot to become active, then run verify-cdc and
#      verify-ingestion as a basic reconciliation gate.
#   8. Trigger a dbt build so curated marts reflect the restored data
#      (unless SKIP_DBT=1).
#
# Usage:
#   make recover-slot                 # interactive, refuses if slot healthy
#   FORCE=1 make recover-slot         # skip prompt + healthy-slot check
#   FORCE=1 SKIP_DBT=1 make recover-slot  # don't run dbt at the end
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ -f "$REPO_ROOT/.env" ]; then
  set -a; source "$REPO_ROOT/.env"; set +a
fi

SOURCE_PG_HOST="${SOURCE_PG_HOST:?SOURCE_PG_HOST not set — source .env first}"
SOURCE_PG_PORT="${SOURCE_PG_PORT:-5432}"
SOURCE_PG_DB="${SOURCE_PG_DB:?SOURCE_PG_DB not set}"
SOURCE_PG_USER="${SOURCE_PG_USER:?SOURCE_PG_USER not set}"
SOURCE_PG_PASSWORD="${SOURCE_PG_PASSWORD:?SOURCE_PG_PASSWORD not set}"
SOURCE_PG_SLOT_NAME="${SOURCE_PG_SLOT_NAME:?SOURCE_PG_SLOT_NAME not set}"
CONNECT_PORT="${CONNECT_PORT:-8083}"
CONNECT_URL="http://localhost:${CONNECT_PORT}"
CONNECTOR_NAME="openlmis-postgres-cdc"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:17-alpine}"

FORCE="${FORCE:-0}"
SKIP_DBT="${SKIP_DBT:-0}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
run_psql() {
  docker run --rm -i \
    --network reporting-shared \
    -e PGPASSWORD="$SOURCE_PG_PASSWORD" \
    "$POSTGRES_IMAGE" \
    psql --host="$SOURCE_PG_HOST" --port="$SOURCE_PG_PORT" \
         --username="$SOURCE_PG_USER" --dbname="$SOURCE_PG_DB" \
         --no-psqlrc --tuples-only --no-align --quiet \
         --set=ON_ERROR_STOP=1 \
         -c "$1"
}

# Fetches the slot row from pg_replication_slots and writes it to a global
# variable. The state classifier is a separate function that reads the row.
# We split these so the caller can both inspect the raw row (for logging)
# and act on the derived state — avoiding the subshell-scope trap where
# $(detect_slot_state) discards any side-effect assignments.
SLOT_ROW=""
fetch_slot_row() {
  if ! SLOT_ROW=$(run_psql "SELECT slot_name, wal_status, active, restart_lsn FROM pg_replication_slots WHERE slot_name='$SOURCE_PG_SLOT_NAME'"); then
    echo "ERROR: could not query pg_replication_slots on $SOURCE_PG_HOST" >&2
    echo "       Check credentials and that the reporting-shared network is up." >&2
    exit 1
  fi
}

# Classifies $SLOT_ROW into one of: "missing" | "invalidated" | "active" | "inactive".
classify_slot() {
  if [ -z "$SLOT_ROW" ]; then
    echo "missing"
    return
  fi
  local wal_status active
  wal_status=$(echo "$SLOT_ROW" | cut -d'|' -f2)
  active=$(echo "$SLOT_ROW" | cut -d'|' -f3)
  if [ "$wal_status" = "lost" ]; then
    echo "invalidated"
  elif [ "$active" = "t" ]; then
    echo "active"
  else
    echo "inactive"
  fi
}

# -----------------------------------------------------------------------------
# 1. Detect slot state
# -----------------------------------------------------------------------------
echo "=== Slot recovery for '$SOURCE_PG_SLOT_NAME' on $SOURCE_PG_HOST ==="
echo ""
echo "Step 1/8 — detecting slot state..."

fetch_slot_row
SLOT_STATE=$(classify_slot)
echo "  pg_replication_slots row: ${SLOT_ROW:-<none>}"
echo "  state:                    $SLOT_STATE"
echo ""

case "$SLOT_STATE" in
  invalidated)
    echo "  → Slot is invalidated (wal_status='lost'). Proceeding with recovery."
    ;;
  missing)
    echo "  → Slot does not exist. Recovery will re-create it from scratch."
    ;;
  active|inactive)
    if [ "$FORCE" = "1" ]; then
      echo "  → WARNING: slot is currently $SLOT_STATE but FORCE=1 — proceeding anyway."
      echo "    This will drop a healthy slot and trigger an unnecessary full re-snapshot."
    else
      cat >&2 <<EOF
ERROR: replication slot '$SOURCE_PG_SLOT_NAME' is $SLOT_STATE, not invalidated.

There is nothing to recover here. Run 'make verify-cdc' to confirm the
pipeline is healthy, or 'make recover' for general pipeline restoration.

If you intentionally want to nuke the slot and re-snapshot everything
(e.g., after a data corruption incident), re-run with:

  FORCE=1 make recover-slot

This $SLOT_STATE state can also appear if a previous 'make recover-slot' run
failed mid-recovery (after the connector was deleted but before the slot
was dropped). In that case the connector is already gone, the slot is
orphaned, and FORCE=1 is the correct continuation path.
EOF
      exit 1
    fi
    ;;
  *)
    echo "ERROR: unknown slot state '$SLOT_STATE'" >&2
    exit 1
    ;;
esac
echo ""

# -----------------------------------------------------------------------------
# 2. Confirmation gate
# -----------------------------------------------------------------------------
echo "Step 2/8 — confirmation"
cat <<EOF

This is a destructive operation. It will:
  - Stop and delete Debezium connector '$CONNECTOR_NAME'
  - Drop replication slot '$SOURCE_PG_SLOT_NAME' from $SOURCE_PG_HOST
  - Re-register the connector, triggering a FULL initial snapshot of
    every table in SOURCE_PG_TABLE_ALLOWLIST
  - Rebuild dbt curated marts (unless SKIP_DBT=1)

ClickHouse 'raw' tables are append-only — existing rows are NOT deleted.
The fresh snapshot adds new op='r' rows; dbt staging models deduplicate
via row_number(). Expect the snapshot phase to take time proportional to
total source data size.

EOF

if [ "$FORCE" != "1" ]; then
  if [ -t 0 ]; then
    printf "Type 'yes' to continue (anything else aborts): "
    read -r CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
      echo "Aborted by user."
      exit 1
    fi
  else
    echo "ERROR: stdin is not a TTY and FORCE=1 was not set — refusing to proceed." >&2
    echo "       Re-run as 'FORCE=1 make recover-slot' for non-interactive use." >&2
    exit 1
  fi
fi
echo ""

# -----------------------------------------------------------------------------
# 3. Stop + delete connector
# -----------------------------------------------------------------------------
echo "Step 3/8 — stopping and deleting connector..."

if curl -sf "$CONNECT_URL/connectors/$CONNECTOR_NAME/status" > /dev/null 2>&1; then
  # Best-effort stop. If the task is FAILED this may not do anything, which
  # is fine — we're about to delete the connector anyway.
  curl -sf -X PUT "$CONNECT_URL/connectors/$CONNECTOR_NAME/stop" > /dev/null 2>&1 || true
  sleep 2
  echo "  Resetting stored offsets..."
  curl -sf -X DELETE "$CONNECT_URL/connectors/$CONNECTOR_NAME/offsets" > /dev/null 2>&1 \
    || echo "  (offset reset failed; will be cleared when connector is deleted)"
  sleep 1
  echo "  Deleting connector..."
  curl -sf -X DELETE "$CONNECT_URL/connectors/$CONNECTOR_NAME" > /dev/null
  sleep 2
else
  echo "  Connector not registered — skipping delete."
fi
echo "  Connector cleared ✓"
echo ""

# -----------------------------------------------------------------------------
# 4. Drop slot from PostgreSQL
# -----------------------------------------------------------------------------
echo "Step 4/8 — dropping replication slot in PostgreSQL..."

# Re-check state: slot may be active if the connector was attached at start
# of this run; after the delete in step 3 it should be inactive.
fetch_slot_row
SLOT_STATE_AFTER_DELETE=$(classify_slot)
case "$SLOT_STATE_AFTER_DELETE" in
  missing)
    echo "  Slot already absent — nothing to drop."
    ;;
  active)
    cat >&2 <<EOF
ERROR: slot '$SOURCE_PG_SLOT_NAME' is still ACTIVE even after deleting the
connector. Another consumer must be attached to it. Identify and stop it,
then re-run:

  SELECT pid, application_name, state, backend_start
  FROM pg_stat_replication
  WHERE pid = (SELECT active_pid FROM pg_replication_slots WHERE slot_name='$SOURCE_PG_SLOT_NAME');
EOF
    exit 1
    ;;
  invalidated|inactive)
    if run_psql "SELECT pg_drop_replication_slot('$SOURCE_PG_SLOT_NAME')" > /dev/null; then
      echo "  Slot dropped ✓"
    else
      echo "ERROR: pg_drop_replication_slot failed" >&2
      exit 1
    fi
    ;;
esac
echo ""

# -----------------------------------------------------------------------------
# 5. Re-register connector (fresh slot + initial snapshot)
# -----------------------------------------------------------------------------
echo "Step 5/8 — re-registering connector (creates fresh slot + initial snapshot)..."
bash "$REPO_ROOT/scripts/connect/register-connector.sh"
echo ""

echo "Step 6/8 — re-initializing ClickHouse raw landing..."
bash "$REPO_ROOT/scripts/clickhouse/init.sh"
echo ""

# -----------------------------------------------------------------------------
# 7. Wait + verify ingestion
# -----------------------------------------------------------------------------
echo "Step 7/8 — waiting for snapshot to start producing rows..."

# Poll the slot until it becomes active (Debezium has reconnected).
DEADLINE=$(( $(date +%s) + 60 ))
STATE="unknown"
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 3
  fetch_slot_row
  STATE=$(classify_slot)
  if [ "$STATE" = "active" ]; then
    echo "  Slot is active ✓ (Debezium attached)"
    break
  fi
  printf "."
done
echo ""

if [ "$STATE" != "active" ]; then
  echo "WARNING: slot did not become active within 60s — Debezium may still be" >&2
  echo "         starting up. The verify steps below are likely to report" >&2
  echo "         issues but the recovery itself is not necessarily broken." >&2
  echo "         Check: make logs SVC=kafka-connect" >&2
fi

# Give the snapshot a few seconds to push some rows before verifying.
sleep 15
bash "$REPO_ROOT/scripts/verify/cdc.sh" || {
  echo "WARNING: verify-cdc reported issues — snapshot may still be in progress" >&2
}
bash "$REPO_ROOT/scripts/verify/ingestion.sh" || {
  echo "WARNING: verify-ingestion reported issues — snapshot may still be in progress" >&2
}
echo ""

# -----------------------------------------------------------------------------
# 8. dbt build (optional)
# -----------------------------------------------------------------------------
if [ "$SKIP_DBT" = "1" ]; then
  echo "Step 8/8 — skipping dbt build (SKIP_DBT=1)"
else
  echo "Step 8/8 — rebuilding dbt models..."
  bash "$REPO_ROOT/scripts/dbt/build.sh" || {
    echo "WARNING: dbt build reported issues — review output above" >&2
  }
fi

echo ""
echo "=== Slot recovery complete ==="
echo ""
echo "Final slot state:"
run_psql "SELECT slot_name, plugin, slot_type, wal_status, active, confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name='$SOURCE_PG_SLOT_NAME'" || true
echo ""
echo "If large tables are still snapshotting, the connector will continue in"
echo "the background. Watch progress with: make logs SVC=kafka-connect"

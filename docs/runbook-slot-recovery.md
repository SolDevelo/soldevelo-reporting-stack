# Runbook: Replication-slot invalidation recovery

When the reporting stack is offline long enough for the source PostgreSQL to exceed `max_slot_wal_keep_size`, PostgreSQL invalidates the logical replication slot. Some changes from the gap are no longer in WAL and cannot be replayed, but the source database still holds the correct *current* state. Recovery rebuilds the baseline by re-snapshotting captured tables through a fresh slot.

This is the highest-impact silent-data-loss scenario for the pipeline. Catch it early, recover deliberately.

## What is preserved

- **Source data** — fully intact in PostgreSQL.
- **ClickHouse raw events** — append-only; existing rows remain. The fresh snapshot adds new `op='r'` rows; dbt staging deduplicates via `row_number()`.
- **dbt models, Superset assets, all package config** — untouched by recovery.

## What is lost

- **Changes that occurred during the outage gap** — any `INSERT`/`UPDATE`/`DELETE` that happened after the slot fell behind and were not yet streamed. After recovery, the curated marts will reflect the **current** state of each captured row, not the intermediate states. If your downstream cares about every transition (audit, change history), reconcile with source DB history tables.

## How to detect slot invalidation

### Symptoms

- `make connector-status` shows the task in `FAILED` state.
- The watchdog repeatedly logs task restarts that fail again immediately.
- Source DB logs contain `replication slot "..." is invalid`.
- `make verify-cdc` fails with "CDC streaming inactive (heartbeat not advancing)".

### Direct check on the source DB

```sql
SELECT slot_name, plugin, slot_type, wal_status, active, restart_lsn
FROM pg_replication_slots
WHERE slot_name = 'debezium_reporting';
```

| `wal_status` | Meaning |
|---|---|
| `reserved` / `extended` | Healthy. |
| `unreserved` | Slot is at risk; falling behind WAL retention. |
| `lost` | **Invalidated.** WAL needed to resume is gone. Run recovery. |

A missing row (zero results) means the slot was already dropped manually — recovery still applies (the connector's stored offsets need to be cleared and a fresh slot created).

## Recovery procedure

### Single-command path

```bash
make recover-slot
```

Interactive. Refuses to run if the slot is healthy. Prompts for explicit `yes` before destructive steps. Use `FORCE=1` for non-interactive (e.g., scripted recovery), and `SKIP_DBT=1` if you want to handle marts separately.

```bash
FORCE=1 make recover-slot           # automate
FORCE=1 SKIP_DBT=1 make recover-slot  # skip the final dbt build
```

### What the command does

1. **Detect** — queries `pg_replication_slots`; refuses healthy slots unless `FORCE=1`.
2. **Confirm** — prints a destructive-action preamble; requires `yes` on stdin (or `FORCE=1`).
3. **Stop + delete the connector** — clears Kafka Connect's stored offsets so Debezium treats the next register as a fresh start.
4. **Drop the orphan slot** — `pg_drop_replication_slot('debezium_reporting')`. Refuses if the slot is still `active` (another consumer is attached); see Troubleshooting below.
5. **Re-register the connector** — Debezium creates a new slot, runs an `initial` snapshot for every table in `table.include.list`. The publication preflight (from Phase 9.1) gates this step.
6. **Re-initialize ClickHouse raw landing** — ensures Kafka-engine + materialized-view tables exist for every topic.
7. **Verify** — waits for the new slot to become `active`, runs `verify-cdc` and `verify-ingestion` as a basic reconciliation gate.
8. **Rebuild dbt curated marts** — unless `SKIP_DBT=1`.

### Expected downtime

- Steps 1–4 (detect, confirm, drop): seconds.
- Step 5 (re-register + snapshot start): seconds to begin; the snapshot itself runs in the background.
- Snapshot completion: minutes to hours, proportional to total source data volume. For an OLMIS Malawi-scale deployment (~10k orderables, ~3k facilities, ~5k requisitions, low five-figure adjustments) expect 5–15 minutes for the full snapshot.
- dbt build: typically 1–3 minutes after the snapshot completes.

Dashboards display stale-but-coherent data during the snapshot — they continue to query curated marts, which only update on the next dbt build. There is no half-state visible to end users.

## Verification

After `make recover-slot` returns:

```bash
make connector-status    # task RUNNING
make verify-cdc          # heartbeat advancing
make verify-ingestion    # raw tables have rows
make dbt-test            # tests pass
```

Spot-check a row count between source and ClickHouse:

```bash
docker exec mw-distro-db-1 psql -U postgres -d open_lmis -tAc \
  "SELECT 'facilities', count(*) FROM referencedata.facilities"
make logs SVC=clickhouse  # or:
docker exec soldevelo-reporting-stack-clickhouse-1 clickhouse-client --query \
  "SELECT count() FROM curated.dim_facility"
```

Counts should match (allow for soft-deletes that the mart filters).

## Troubleshooting

### "Slot is still ACTIVE even after deleting the connector"

Something else is consuming the slot. Common cases:

- A second Kafka Connect worker (split-brain after a restart). Inspect:

  ```sql
  SELECT pid, application_name, state, backend_start
  FROM pg_stat_replication
  WHERE pid = (SELECT active_pid FROM pg_replication_slots WHERE slot_name='debezium_reporting');
  ```

- A manual `pg_recvlogical` session — terminate it on the source host.

After identifying and stopping the active consumer, re-run `make recover-slot`.

### "ERROR: slot is X, not invalidated"

The slot is healthy. `make recover-slot` refuses to run because the destructive path would re-snapshot unnecessarily. If you intentionally want to nuke a healthy slot (e.g., after a data corruption incident), pass `FORCE=1`.

### Snapshot runs but ClickHouse counts stay at zero

- Check connector logs: `make logs SVC=kafka-connect | grep -i error`
- Check Kafka topics exist: open Kafka UI at `http://localhost:9080`.
- ClickHouse Kafka-engine table reading? `SELECT * FROM system.kafka_consumers` in ClickHouse.

### Publication-preflight fails during step 5

This means the new `register-connector` call detected publication drift — tables in `SOURCE_PG_TABLE_ALLOWLIST` are not in the publication. Apply the suggested `ALTER PUBLICATION` and persist the change in `reporting-stack/init-db.sql`, then re-run.

### `make recover-slot` itself failed partway through

Two danger windows exist between the script's destructive steps:

- **Window A — after step 3, before step 4.** The connector has been deleted but the orphan slot still exists. A re-run of `make recover-slot` will classify the slot as `inactive` (not `invalidated`) and refuse to proceed because the healthy-slot guard fires. The fix is to re-run with `FORCE=1`:

  ```bash
  FORCE=1 make recover-slot
  ```

  Detect this case by running `make connector-status` — if it reports "connector not found" but `pg_replication_slots` still has a row for `debezium_reporting`, you're in Window A.

- **Window B — after step 4, before step 5.** The slot is gone and the connector is gone. `make recover-slot` classifies the slot as `missing` and proceeds normally on the next run; no special flags needed.

If the script fails outside these windows (e.g., during the snapshot wait or the dbt build), the pipeline is in a recoverable state — you can simply re-run the failing step (`make verify-cdc`, `make dbt-build`) without re-running the whole recovery.

## Prevention

`max_slot_wal_keep_size` (configured to 2GB in the mw-distro / ref-distro overlay) bounds the WAL retention. Once the reporting stack is offline for long enough to exceed that, invalidation is inevitable. Mitigations:

- **Operational:** keep the reporting stack up; alert on connector task failures (monitoring work is the remaining post-MVP item).
- **Tuning:** raise `max_slot_wal_keep_size` (more headroom; more disk).
- **Architectural:** the watchdog auto-restarts FAILED tasks but cannot recover from slot invalidation — that requires the destructive path here.

> **Note on manual slot drops:** if a DBA drops the replication slot out-of-band (`SELECT pg_drop_replication_slot(...)`), the connector's stored offsets in Kafka Connect will point at an LSN that no longer exists. The connector config uses `snapshot.mode=when_needed`, so Debezium detects this on the next start and runs a fresh snapshot automatically — there is no operator prompt before the re-snapshot. If you want to gate this, terminate the connector cleanly first (`make delete-connector`) and use `make recover-slot` instead.

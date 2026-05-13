# Runbook: Add new source tables to CDC

This runbook covers the end-to-end procedure for capturing a new source table after the reporting stack is already running. It applies to both fresh and long-running deployments.

The goal is **safe, incremental** capture: existing tables keep their offsets and data, the new tables are snapshotted into ClickHouse alongside the live CDC stream, no full re-snapshot needed.

## Prerequisites

- Both stacks are running (source + reporting). Verify with `make verify-services && make verify-cdc`.
- The reporting stack's source DB init SQL has been applied (it creates `public.debezium_signal` and adds it to the publication). For mw-distro / ref-distro this happens automatically via the `reporting-stack-init` container; for production deployments see [source-db-setup.md](source-db-setup.md).
- The source database user has privileges to ALTER PUBLICATION and SELECT from the new tables.

## Procedure

### 1. Identify the tables

Decide which tables to add. Use the fully-qualified `schema.table` form. Example: `referencedata.facility_operators`.

Check that each table has a **primary key**. Debezium incremental snapshots require one — tables without a PK cannot be incrementally snapshotted (they can still be captured for change events, but you'd need a full reset to backfill historical rows).

```sql
-- Run against the source DB
SELECT c.conname, c.contype
FROM pg_constraint c
JOIN pg_class t ON t.oid = c.conrelid
JOIN pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'referencedata' AND t.relname = 'facility_operators'
  AND c.contype = 'p';
```

If no row is returned, the table has no PK. Stop and add one, or fall back to `MODE=reset` (Step 4 below) — but the latter re-snapshots everything.

### 2. Add the tables to the publication

Edit the source DB init SQL — the same file in both lists (`CREATE PUBLICATION` and `ALTER PUBLICATION ... SET TABLE`):

- mw-distro: `../mw-distro/reporting-stack/init-db.sql`
- ref-distro: `../openlmis-ref-distro/reporting-stack/init-db.sql`
- production: your equivalent init SQL maintained alongside the source DB

Then re-run the init SQL. For the mw-distro / ref-distro overlay this happens automatically when the `reporting-stack-init` container starts; for an already-running stack you can apply the change manually:

```bash
docker compose -p mw-distro exec db psql -U postgres -d open_lmis \
  -c "ALTER PUBLICATION dbz_publication ADD TABLE referencedata.facility_operators;"
```

Verify:

```bash
docker compose -p mw-distro exec db psql -U postgres -d open_lmis \
  -c "SELECT * FROM pg_publication_tables WHERE pubname = 'dbz_publication' ORDER BY tablename;"
```

> **Preflight safety net:** `make register-connector` (and therefore `make connector-refresh`) queries `pg_publication_tables` and fails fast if any table in `SOURCE_PG_TABLE_ALLOWLIST` is missing from the publication. The error message lists the missing tables and the exact `ALTER PUBLICATION` to run. Forget step 2? You'll hear about it before silent data loss can happen. Bypass with `SKIP_PREFLIGHT=1` only when you're intentionally registering ahead of the publication change.

### 3. Update `SOURCE_PG_TABLE_ALLOWLIST`

In the reporting stack's `.env`, append the new tables to `SOURCE_PG_TABLE_ALLOWLIST` (comma-separated, no spaces):

```env
SOURCE_PG_TABLE_ALLOWLIST=referencedata.facilities,...,referencedata.facility_operators
```

Also persist the change in your env template (`/home/user/workspace/openlmis/env.mw-distro` or your deployment-specific file) so it survives a `cp ../env.mw-distro .env`.

### 4. Refresh the connector + snapshot only the new tables

```bash
make connector-refresh
```

This is `MODE=auto` (the default). It will:

1. Detect that the new tables are in `.env` but not in the connector's current `table.include.list`.
2. Re-register the connector with the updated allowlist.
3. Re-initialize ClickHouse raw landing (creates `raw.kafka_*` and `raw.events_*` tables for the new topics).
4. Insert a row into `public.debezium_signal` telling Debezium to incrementally snapshot the new tables.
5. Print where to watch progress.

Output will include:

```
Desired allowlist: ...,referencedata.facility_operators
Current allowlist: ...
New tables:        referencedata.facility_operators
...
Triggering incremental snapshot for new tables: referencedata.facility_operators
```

### 5. Watch the snapshot complete

```bash
make logs SVC=kafka-connect | grep -i "incremental snapshot"
```

Expected log lines:

```
Requested 'INCREMENTAL' snapshot of data collections '[referencedata.facility_operators]'
Schema for incremental snapshot table 'referencedata.facility_operators' is locked.
Incremental snapshot for table 'referencedata.facility_operators' is finished.
```

Then check ClickHouse:

```bash
make verify-ingestion
docker compose -p openlmis-reporting exec clickhouse \
  clickhouse-client --query "SELECT count() FROM raw.events_openlmis_referencedata_facility_operators"
```

Row count should match the source table's count.

### 6. Add dbt models and Superset assets

Capture is now live, but the new data isn't yet in any curated mart. To surface it:

- Add a staging model under `dbt/models/staging/` (or in your analytics package).
- Add or extend a mart model under `dbt/models/marts/`.
- Update the corresponding Superset dataset YAML — see the [Mart + dataset gotcha](usage-guide.md) (every mart column must also exist in the dataset YAML).

Then:

```bash
make dbt-build
make superset-import
```

## Troubleshooting

### "ERROR: public.debezium_signal does not exist"

The signal table wasn't created. Either:

- The source DB init SQL wasn't re-run with this version of the platform → re-apply `reporting-stack/init-db.sql`.
- The table was dropped manually → re-create it with the SQL from the init script.

As a temporary workaround, you can use `MODE=reset` (Step 7 below).

### "New tables: <none>" but I added tables

- Did you save `.env` after editing? `make connector-refresh` reads from `.env`, not your shell environment.
- Are the new tables in the `SOURCE_PG_TABLE_ALLOWLIST` env var of the reporting stack, not the env file of mw-distro?

### Snapshot rows never appear in ClickHouse

1. `make connector-status` — task must be `RUNNING`. If `FAILED`, look at the trace; common cause is the user lacking SELECT privilege on the new schema.
2. `make logs SVC=kafka-connect | grep -i error`
3. Check the Kafka topic exists: open Kafka UI at `http://localhost:9080`, look for `<prefix>.<schema>.<table>`.
4. Check the ClickHouse Kafka engine table is reading: `SELECT * FROM system.kafka_consumers`.

### Auto-mode refresh says "no new tables" but I want a re-snapshot

`make connector-refresh` (auto mode) treats a table as new only if it's in your `.env` allowlist but not yet in the connector's current `table.include.list`. If a previous snapshot was interrupted (e.g., container killed mid-chunk) the table is already in both lists, so the auto diff finds nothing.

To force a re-snapshot of a specific table, use the explicit incremental path:

```bash
MODE=incremental TABLES=schema.table make connector-refresh
```

This skips the diff and triggers `make snapshot-tables` directly. Incremental snapshots produce duplicate rows for already-captured data; dbt staging dedupes via `row_number()`, so it's safe.

### 7. Last resort: `MODE=reset`

If incremental snapshot is unavailable (e.g., signal table missing, or the new table has no PK), fall back to:

```bash
make connector-refresh MODE=reset
```

This deletes the connector, drops stored offsets, and re-registers — triggering Debezium's built-in initial snapshot for **every** captured table. Existing rows in ClickHouse `raw` tables are not deleted; the snapshot inserts duplicate rows, which dbt staging models deduplicate via `row_number()`. Expect ingestion to be slow proportional to total source data size.

## Rollback

To remove a table after adding it:

1. Edit the publication SQL and `SOURCE_PG_TABLE_ALLOWLIST` to drop the table.
2. `make register-connector` (no snapshot needed for removal).
3. Optionally drop the corresponding `raw.kafka_*` / `raw.events_*` ClickHouse tables and the Kafka topic. The reporting stack tolerates leftover topics and tables; they just stop receiving new rows.

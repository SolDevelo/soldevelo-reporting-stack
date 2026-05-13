# Runbook: Initial load for a new deployment

Bring up the reporting stack against a new source database that already contains data. The goal is to backfill historical/current state into ClickHouse and start CDC from a known point — without waiting on Debezium's chunk-based initial snapshot for large tables.

The bootstrap path uses PostgreSQL's `COPY` for the bulk read and inserts synthetic `op='r'` events directly into ClickHouse raw tables. It is significantly faster than Debezium's built-in initial snapshot for large datasets (millions of rows), and roughly equivalent for small ones (use what's simpler in that case — see "When NOT to use this path" below).

## Outcome

After this runbook, the deployment is in the same end state as a clean `make setup` would produce:

- ClickHouse `raw.events_*` tables contain `op='r'` rows for every captured table.
- Debezium streams live changes from the point at which the connector was registered.
- dbt curated marts are built and Superset dashboards work.

## Prerequisites

- The source PostgreSQL is reachable on the `reporting-shared` Docker network as `${SOURCE_PG_HOST}` (e.g., `olmis-db` for mw-distro / ref-distro).
- The source DB has been initialised with the reporting-stack init SQL — publication exists, signal table exists, replication role has been granted. See [source-db-setup.md](source-db-setup.md).
- `.env` is configured for the target deployment: `SOURCE_PG_*`, `DEBEZIUM_TOPIC_PREFIX`, `SOURCE_PG_TABLE_ALLOWLIST`.

## When NOT to use this path

- **Small datasets (< a few hundred thousand rows total).** Debezium's initial snapshot completes in single-digit minutes. The bootstrap path adds operational steps without saving meaningful time.
- **Source tables without primary keys.** dbt staging uses PKs for dedup; bootstrap rows would coexist with Debezium snapshot rows ambiguously.
- **When you don't have direct PG access from the reporting stack host.** The export uses a one-shot `postgres:17-alpine` container on the `reporting-shared` Docker network. No `pg_dump`/`psql` is required on the host.

If any of the above apply, use the standard `make setup` flow instead.

## Procedure

```text
                                  +-------------------+
                                  |   Source PG       |
                                  |   (current state) |
                                  +---------+---------+
                                            |
                              (1) bootstrap-export (COPY row_to_json)
                                            v
                              .bootstrap/export-<ts>/*.ndjson + manifest.json
                                            |
                              (2) bootstrap-import (wrap as op='r' events)
                                            v
                                  +-------------------+
                                  |  ClickHouse raw   |
                                  |  events_<topic>   |
                                  +-------------------+
                                            ^
                              (3) register-connector with snapshot.mode=no_data
                                            |  (records LSN, no data snapshot)
                                  Source PG --[CDC]--> Kafka --> ClickHouse raw
                                            v
                              (4) dbt build (curated marts populated)
```

### 1. Start the platform services

```bash
cp /path/to/your-env.env .env
make up
make verify-services
make clickhouse-init     # ensures raw.events_<topic> tables exist for every table in the allowlist
```

Do **not** run `make setup` (it would register the connector and trigger Debezium's initial snapshot).

### 2. Export data from the source

```bash
make bootstrap-export
```

This pg_dumps every table in `SOURCE_PG_TABLE_ALLOWLIST` (except the signal table) to NDJSON under `.bootstrap/export-<timestamp>/`. A `manifest.json` is written with the export wall-clock, the source WAL LSN at the start of the export, and per-table row counts. The symlink `.bootstrap/latest` points to the new directory.

For a subset of tables:

```bash
TABLES=referencedata.facilities,requisition.requisitions make bootstrap-export
```

> **Atomicity note:** the export is *not* atomic across tables — each table is exported in its own transaction. If your source DB receives writes during the export, inter-table state may be momentarily inconsistent (e.g., a `requisition` row referencing a `facility` that was modified mid-export). Once CDC is running in step 4, the live stream will reconcile any skew within one propagation cycle. For strict consistency, take the export against a quiet source DB or wrap the export in a serializable transaction (out of scope here).

### 3. Import into ClickHouse

```bash
make bootstrap-import
```

Reads `.bootstrap/latest/manifest.json`, transforms each NDJSON row into a synthetic CDC envelope (`op='r'`, `ts_ms` from the export wall-clock, `source.snapshot='bootstrap'`, `source.lsn` from the manifest), and inserts into `raw.events_<topic>` via the ClickHouse HTTP API.

Idempotency: re-running an import lands additional rows in the append-only raw table. dbt staging deduplicates by primary key ordering by `ts_ms` then `_ingested_at` (newest wins), so a re-run gives the freshest state.

### 4. Register the connector with `no_data` snapshot mode

```bash
DEBEZIUM_SNAPSHOT_MODE=no_data make register-connector
```

`no_data` (Debezium 2.5+) records the table structure and the current LSN as the streaming starting point — but does **not** copy data. This is exactly what we want: data is already in ClickHouse via step 3; the connector should only stream changes from this point forward.

Persist this in your `.env` if it's a one-shot decision per environment, otherwise leave the default (`when_needed`) and pass the env var per invocation.

### 5. Build dbt curated marts

```bash
make dbt-build
```

The staging models read from `raw.events_<topic>` and pick the latest version per primary key. Bootstrap rows (`op='r'`, `source.snapshot='bootstrap'`) are equivalent to a CDC snapshot row for staging purposes.

### 6. Verify

```bash
make verify-cdc           # connector running, heartbeat advancing
make verify-ingestion     # raw tables have rows
make verify-dbt           # dbt build succeeded, marts populated
```

Spot-check a row count between source and a curated mart:

```bash
docker exec mw-distro-db-1 psql -U postgres -d open_lmis -tAc \
  "SELECT count(*) FROM referencedata.facilities WHERE active=true"
docker exec soldevelo-reporting-stack-clickhouse-1 clickhouse-client --query \
  "SELECT count() FROM curated.dim_facility"
```

(Counts should match, allowing for mart-side filters like soft-deletes.)

## Troubleshooting

### Export fails with "no such schema/table"

The table list (`SOURCE_PG_TABLE_ALLOWLIST` or `TABLES=`) references something that doesn't exist in the source DB. Double-check the names with:

```bash
docker run --rm --network reporting-shared -e PGPASSWORD=$SOURCE_PG_PASSWORD postgres:17-alpine \
  psql -h $SOURCE_PG_HOST -U $SOURCE_PG_USER -d $SOURCE_PG_DB \
  -c "SELECT schemaname || '.' || tablename FROM pg_tables WHERE schemaname IN ('referencedata','requisition') ORDER BY 1"
```

### Import says "raw.events_<topic> does not exist"

You skipped `make clickhouse-init` or the topic prefix in the table name doesn't match `DEBEZIUM_TOPIC_PREFIX`. Re-run `make clickhouse-init`.

### After step 4, the connector task is FAILED with "this is no longer available on the server"

The Connect-side stored offsets from a previous deployment attempt are stale (Kafka Connect persists offsets in its internal `connect-offsets` topic by connector name; `DELETE /connectors/<name>` does NOT remove them — they are reused on the next register). `snapshot.mode=no_data` does **not** recover from stale offsets the way `when_needed` does — it relies on a clean offset state.

Reset offsets explicitly via the REST API (the connector must be in STOPPED state for this endpoint to work):

```bash
curl -X PUT  http://localhost:8083/connectors/openlmis-postgres-cdc/stop
curl -X DELETE http://localhost:8083/connectors/openlmis-postgres-cdc/offsets
curl -X PUT  http://localhost:8083/connectors/openlmis-postgres-cdc/resume
```

Wait ~10 seconds, then check `make connector-status`. The task should now be RUNNING with a fresh slot.

### Connector heartbeat doesn't advance after registration

The connector with `no_data` records the LSN at registration time but won't stream until a real WAL event appears. The heartbeat table (`public.reporting_heartbeat`) advances every 10 seconds — wait at least one full heartbeat interval before declaring this broken.

## What's "lost" with this path vs `make setup`

Nothing functionally. The end state is data-equivalent to `make setup` for the captured tables, but the bootstrap-loaded events have a few cosmetic differences in the `source` envelope field that no current dbt model reads:

| Field | Bootstrap value | Debezium snapshot value |
|---|---|---|
| `source.snapshot` | `"bootstrap"` | `"first"` |
| `source.name` | `"bootstrap-import"` | `<topic.prefix>` (e.g., `"openlmis"`) |
| `source.version` | `"bootstrap"` | `"3.5.0.Final"` |
| `source.txId` | `null` | actual transaction ID at snapshot time |
| `source.lsn` | LSN captured at start of export | actual LSN of the snapshot transaction |

These differences are informational; the `after` payload (the actual row data) is identical between bootstrap-imported rows and Debezium-snapshot rows. If you later add dbt models or external tooling that inspects `source.*`, plan for both formats.

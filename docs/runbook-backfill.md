# Runbook: Targeted backfill

Rebuild specific tables in ClickHouse from the current source state — without disrupting live CDC. Use this when:

- A dbt model was wrong and we need fresh row data to rebuild it correctly.
- A table's CDC stream had a gap (rare; usually handled by [slot recovery](runbook-slot-recovery.md)) and you only want to repair a subset.
- You want to audit ClickHouse contents against the source as of a specific time.

## Choosing between this and `make snapshot-tables`

Both backfill specific tables, but the mechanism is different:

| Tool | Mechanism | When to prefer |
|---|---|---|
| `make snapshot-tables TABLES=…` | Debezium incremental snapshot via signal channel. Re-reads tables chunk-by-chunk alongside live CDC. | Default for "I want fresh rows but don't want to disturb CDC." Slower for very large tables but no manual coordination. |
| `make bootstrap-export` + `make bootstrap-import` | `COPY` from source, direct INSERT into ClickHouse. | Faster for very large tables. Useful when Debezium snapshot is too slow or the signal channel is unavailable. |

For most backfills on Malawi-scale data, prefer `make snapshot-tables`. The export/import path here is mainly for performance on larger deployments and for parity with the [initial-load runbook](runbook-initial-load.md).

## What is lost and preserved

- **Preserved:** Live CDC stream is not interrupted. ClickHouse `raw` is append-only — existing rows are not deleted.
- **Lost:** Nothing. Bootstrap-imported rows have `ts_ms` set to the export wall-clock; dbt staging's `row_number() ORDER BY ts_ms DESC, _ingested_at DESC` picks the newest version per primary key. If CDC has more recent events for any row, CDC wins; if the export is more recent, the bootstrap wins.

## Procedure

### 1. Identify the tables to refresh

A list of `schema.table` names. Example: a stockmanagement dashboard was wrong, and we want to refresh `requisition.stock_adjustments` and `requisition.stock_adjustment_reasons`.

### 2. Export

```bash
TABLES=requisition.stock_adjustments,requisition.stock_adjustment_reasons make bootstrap-export
```

This produces `.bootstrap/export-<timestamp>/` with NDJSON files and a manifest. The CDC stream is untouched.

### 3. Import into ClickHouse raw

```bash
make bootstrap-import
```

Reads `.bootstrap/latest/manifest.json` and writes `op='r'` events with `source.snapshot='bootstrap'` into the corresponding `raw.events_*` tables. Idempotent.

### 4. Rebuild affected marts

```bash
make dbt-build
```

Or, if you know exactly which models depend on the refreshed tables, scope it:

```bash
bash scripts/dbt/run.sh build --select +mart_adjustments
```

### 5. Verify

```bash
make verify-dbt
```

Or run `make reconcile` for cross-system row count + PK-checksum comparison across all tagged marts. For an ad-hoc spot check on one table:

```bash
# source PG
docker compose --env-file .env -f compose/docker-compose.yml exec clickhouse \
  clickhouse-client --query "
SELECT 'source', count() FROM postgresql('${SOURCE_PG_HOST}:${SOURCE_PG_PORT}', '${SOURCE_PG_DB}',
  'stock_adjustments', '${SOURCE_PG_USER}', '${SOURCE_PG_PASSWORD}', 'requisition')
UNION ALL
SELECT 'target', count() FROM curated.mart_adjustments"
```

## Troubleshooting

### A row I just changed at the source is not in the refreshed mart

Either:

- The change happened after the export — wait for the next CDC propagation cycle (a few seconds) and re-run `make dbt-build`.
- The change happened before the export but isn't in the mart — check the dbt model logic; the staging dedup picks newest `ts_ms`. Bootstrap rows have `ts_ms = export wall-clock`. If a CDC event with an older `ts_ms` is somehow newer in `_ingested_at`, it would still lose the dedup (`ts_ms` comes first in the ordering).

### "ERROR: raw.events_<topic> does not exist"

`make clickhouse-init` hasn't been run for that topic. New tables added to the allowlist need ClickHouse-side raw tables created before they can receive imports — `make clickhouse-init` is idempotent and creates them.

### My .bootstrap directory is getting large

`.bootstrap/` is gitignored. Old exports can be safely deleted; the `latest` symlink can be re-pointed manually or by re-running `make bootstrap-export`.

```bash
rm -rf .bootstrap/export-20*    # delete all timestamped exports
make bootstrap-export           # create a fresh one
```

## See also

- [runbook-add-tables.md](runbook-add-tables.md) — adding new tables to CDC
- [runbook-slot-recovery.md](runbook-slot-recovery.md) — recovering from invalidated replication slot
- [runbook-initial-load.md](runbook-initial-load.md) — full-deployment bootstrap path

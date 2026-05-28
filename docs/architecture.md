# Architecture

## Key principles

- **CDC from DB, not API polling**: captures changes directly from PostgreSQL WAL. Removes dependency on API permissions, eliminates sync race conditions, and ensures data completeness.
- **Separation of concerns**: ingestion (Debezium/Kafka), storage/query (ClickHouse), transformations (dbt), orchestration (Airflow), and visualization (Superset) are independent layers.
- **Raw landing as immutable event log**: append-only storage of all CDC events with metadata. Enables debugging, replay, and targeted backfills. Subject to retention/TTL policies.
- **Curated marts are the BI contract**: dashboards and BI tools (Superset, Power BI) connect only to curated marts, never to raw CDC tables. This provides a stable interface that survives ingestion/transformation changes.
- **Recoverability**: raw landing layer allows rebuilding curated marts after logic fixes without re-ingesting from source.
- **Data quality as a first-class feature**: minimum test suite required on all curated marts — integrity (`not_null`, `unique`), relationships (FK checks), accepted values (enumerations/status fields), freshness SLAs, and reconciliation (counts/sums between staging and marts). If critical tests fail, dashboards should be treated as potentially stale.
- **Superset assets as code**: dashboards/charts/datasets stored as unzipped YAML in Git (source of truth), not as UI-only state. Database credentials must never be stored in Git — inject at deploy time via environment variables. Change workflow: author in UI → export YAML from controlled environment → commit to appropriate repo → PR review → automated import.
- **Use current, supported component versions**: avoid reintroducing legacy maintenance risks. Especially relevant for Superset (upgrade to current release) and supporting components (Kafka, Debezium, ClickHouse).

## Platform vs adopter responsibilities

The **platform** (this repo) provides infrastructure, runtime composition, scripts, and generic tooling. **Adopters** provide domain-specific reporting logic via analytics packages:

- **Core package** (required): Debezium connector config, dbt models/tests/seeds, Superset assets-as-code
- **Extension packages** (optional, additive): additional dbt marts and Superset dashboards

Extensions may only **add** new assets. They must not modify core models/dashboards or change ingestion contracts (extend-only rule).

## Package contract

An analytics package is a Git repository (or local directory) with this layout:

```
manifest.yaml              # name, type (core|extension), compatibility
connect/                   # Debezium connector JSON templates (core only)
dbt/
  dbt_project.yml          # dbt package config
  models/                  # dbt models (staging, marts)
  tests/                   # dbt tests
  seeds/                   # dbt seed files
superset/
  assets/                  # unzipped YAML (dashboards, charts, datasets)
README.md
```

### manifest.yaml

Every package must include a `manifest.yaml` at its root:

```yaml
name: olmis-analytics-core
type: core                   # core or extension
platform_version: ">=1.0.0"  # platform compatibility constraint
description: "..."
includes:                    # which components the package provides
  - connect                  # core only — extensions must not include this
  - dbt
  - superset
```

### Loading modes

**Local mode** (development): set `ANALYTICS_CORE_PATH` and `ANALYTICS_EXTENSIONS_PATHS` in `.env` to filesystem paths. This is the default — the built-in examples under `examples/` work out of the box.

**Git mode** (production): set `ANALYTICS_CORE_GIT_URL` and `ANALYTICS_CORE_GIT_REF` in `.env`. dbt uses its native `git:` package support to fetch models directly. For non-dbt components (connector config, Superset assets), run `make package-fetch` which clones repos to `.packages/`.

### Extend-only rule

Extensions may only **add** new assets. They must not:
- Include a `connect/` directory (ingestion is owned by the core package)
- Define dbt models with the same name as core models
- Use Superset asset UUIDs that collide with core UUIDs

Run `make package-validate` to enforce these rules.

See `examples/olmis-analytics-core/` for a reference core package and `examples/olmis-analytics-malawi/` for a reference extension.

## Data flow

```
Adopter PostgreSQL (external)
  │
  ├─▶ Debezium CDC (Kafka Connect plugin)          ─┐
  │     └─▶ Kafka (KRaft, no ZooKeeper)              │ real-time (seconds)
  │           └─▶ ClickHouse raw landing            ─┘
  │
  └─▶ scripts/bootstrap/export.sh (COPY → NDJSON)  ─┐
        └─▶ scripts/bootstrap/import.sh             │ on-demand (operator-triggered)
              └─▶ ClickHouse raw landing           ─┘   for initial-load + targeted backfill

                    ClickHouse
                    ├─▶ raw landing (append-only, for debug/replay/backfill)
                    │     ↑
                    │     │  control plane: public.debezium_signal (operator inserts
                    │     │  signal rows → Debezium runs incremental snapshots without
                    │     │  resetting offsets; used by make snapshot-tables)
                    │     │
                    └─▶ curated marts (BI contract — dashboards query only these)
                          ├─▶ dbt Core transformations  ── scheduled (default: hourly)
                          │     └─▶ Airflow orchestration
                          └─▶ Superset / Power BI
```

The bootstrap path emits synthetic `op='r'` events with `source.snapshot='bootstrap'` so the same dbt staging logic deduplicates bootstrap and CDC rows together (newest `ts_ms` wins). See [runbook-initial-load.md](runbook-initial-load.md) and [runbook-backfill.md](runbook-backfill.md) for when to use this path.

## ClickHouse raw landing pattern

For each CDC topic, the platform creates:

| Table | Engine | Purpose |
|---|---|---|
| `raw.kafka_<topic>` | Kafka Engine | Consumes JSON CDC events from Kafka |
| `raw.events_<topic>` | MergeTree | Append-only storage (configurable TTL, default 90 days via `RAW_TTL_DAYS`) |
| `raw.mv_<topic>` | Materialized View | Routes Kafka → MergeTree, filters deserialization errors |

Each event stores the full Debezium envelope as JSON strings: `op`, `ts_ms`, `before`, `after`, `source`, `transaction`. The dbt layer parses these into typed columns and reconstructs current-state rows.

## dbt transformation pattern

dbt runs via Docker (`dbt/Dockerfile`) with dbt-core + dbt-clickhouse adapter. The platform provides a runner project (`dbt/`) and generic macros; adopter packages provide models via dbt's local package mechanism.

| Layer | Schema | Materialization | Purpose |
|---|---|---|---|
| Staging — small dimensions (`stg_facilities`, `stg_programs`, `stg_geographic_zones`, etc.) | `curated` | View | Current-state reconstruction from raw CDC events via `row_number()` + JSON extraction. Cheap to recompute on every query because the underlying raw event tables are small. |
| Staging — fact-shaped (`stg_requisitions`, `stg_requisition_line_items`, `stg_status_changes`, `stg_stock_adjustments`, `stg_stock_adjustment_reasons`) | `curated` | Incremental MergeTree (`delete_insert` by primary key) | Same current-state semantics, but materialized so the JSON parsing + dedupe runs once per dbt cycle instead of on every mart query. Each row carries an internal `_cdc_ts` (watermark) used by incremental marts and the next run of the staging model itself. |
| Marts — dimensions and small aggregates (`mart_facility_directory`, `mart_requisition_summary`, `mart_reporting_status`, `mart_non_reporting_facilities`, `mart_logistics_summary`, `mart_malawi_*`) | `curated` | MergeTree table (`materialized='table'`) | Full rebuild each refresh. Cheap because their largest scan is below ~1.2 M rows. |
| Marts — big fact aggregates (`mart_stock_status`, `mart_adjustments`) | `curated` | Incremental MergeTree (`delete_insert` by primary key) | Watermark off the fact-side `stg_*._cdc_ts`. Routine refreshes only process line items whose latest CDC event arrived since the previous run. |

Staging models handle CDC semantics: for each primary key, they select the latest event by `ts_ms` and `_ingested_at`, excluding deletes (`op != 'd'`). This deterministic logic correctly handles initial snapshots, incremental changes, and replay scenarios.

**Why the materialization mix.** Pure `table` was the original choice — simple and correctness-free re late-arriving data. It became the structural blocker on real-scale data (`mart_stock_status` joined 28 M+ line items and approached ClickHouse's host memory limit on every refresh). Pure `incremental` everywhere would trade that for new bug surfaces (late-arriving data, source deletes, watermark drift) on marts whose full rebuild is already cheap. The mix above promotes only the models whose full rebuild is too expensive, leaving the rest as the simpler `table`. Adopters with bigger datasets follow the same rule: stay as `table` until measurement says otherwise. See `docs/incremental-refactor-plan.md` for the per-mart audit and decision rationale.

**Source-delete handling.** Incremental staging and incremental marts use `delete_insert` with the natural primary key. Updates and inserts upsert cleanly. Hard-deletes from source leave the latest CDC event as `op='d'`, which is filtered out of the SELECT — so the stale row remains in the materialized table. In OpenLMIS this is extremely rare for the affected tables. Reconcile via `dbt run --full-refresh` when source deletes are suspected.

**Dimension drift.** Incremental marts watermark on their fact-side `stg_*._cdc_ts`. Changes to facility names, program names, period dates, etc. don't propagate to existing mart rows on an incremental run — only on a `--full-refresh`. Operator should `--full-refresh` periodically (e.g. monthly) to reconcile dimension drift, or whenever a known dimension change needs to surface in dashboards immediately.

**Error handling:** Kafka Engine tables use `kafka_handle_error_mode = 'stream'`. Malformed messages are filtered out by the Materialized View (`WHERE length(_error) = 0`) and silently skipped — there is no DLQ. See [development.md](development.md#error-handling) for diagnostics.

## Data freshness and refresh latency

Understanding how quickly a change in the source database appears on a dashboard requires understanding the latency at each layer:

| Layer | Latency | What happens |
|---|---|---|
| **CDC capture** (Debezium) | Seconds | Change is captured from PostgreSQL WAL and published to Kafka |
| **Raw landing** (ClickHouse Kafka Engine) | Seconds | Kafka message is consumed and stored in `raw.events_*` tables |
| **Curated marts** (dbt via Airflow) | **Depends on schedule** | dbt rebuilds mart tables from raw events. Only runs when Airflow triggers it |
| **Dashboards** (Superset / Power BI) | Depends on cache settings | BI tool queries the curated mart. May serve cached results |

The first two layers are near-real-time — a database change reaches ClickHouse's raw landing within seconds. The bottleneck for dashboard freshness is the **dbt refresh schedule**, controlled by Airflow.

### Refresh schedule

Airflow runs the `platform_refresh` DAG on a configurable schedule (default: `@hourly`). This means curated marts — and by extension, dashboards — reflect data up to one hour old in the default configuration.

**Choosing a schedule:**

| Schedule | Use case |
|---|---|
| `*/15 * * * *` (every 15 min) | Active monitoring, operational dashboards |
| `@hourly` (default) | General reporting, good balance of freshness vs. resource usage |
| `0 */4 * * *` (every 4 hours) | Periodic reporting, resource-constrained environments |
| `@daily` | End-of-day reporting, minimal resource impact |

Configure via `AIRFLOW_REFRESH_SCHEDULE` in `.env`. Any [cron expression](https://crontab.guru/) or Airflow preset (`@hourly`, `@daily`) is supported.

### Freshness gate

Before running dbt, Airflow checks whether raw data is actually fresh (new CDC events have arrived since the last check). If no new data has arrived within `FRESHNESS_MAX_AGE_MINUTES` (default: 60), the DAG skips the dbt run — saving compute when there are no changes to process.

### Manual refresh

To refresh marts immediately after a known change (e.g., after creating a requisition), trigger the DAG manually from the Airflow UI or run:

```bash
make dbt-build              # incremental refresh — cheap, picks up the delta since the last run
make initial-dbt-build      # one-time full refresh — heavy, only after a fresh deploy or to reconcile dimension/3-year-window drift
```

See [operations.md](operations.md#deployment-lifecycle) for the full lifecycle (fresh deploy, redeploy/restart, routine refresh, full reconcile) and when each command is the right one.

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
  models/                  # dbt models (staging, marts)
  tests/                   # dbt tests
  seeds/                   # dbt seed files
superset/
  assets/                  # unzipped YAML (dashboards, charts, datasets)
README.md
```

Packages are loaded via local paths (development) or pinned Git refs (production). See `examples/olmis-analytics-core/` for a reference implementation.

## Data flow

```
Adopter PostgreSQL (external)
  └─▶ Debezium CDC (Kafka Connect plugin)          ─┐
        └─▶ Kafka (KRaft, no ZooKeeper)              │ real-time (seconds)
              └─▶ ClickHouse                         ─┘
                    ├─▶ raw landing (append-only, for debug/replay/backfill)
                    └─▶ curated marts (BI contract — dashboards query only these)
                          ├─▶ dbt Core transformations  ── scheduled (default: hourly)
                          │     └─▶ Airflow orchestration
                          └─▶ Superset / Power BI
```

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
| Staging (`stg_*`) | `curated` | View | Current-state reconstruction from raw CDC events via `row_number()` + JSON extraction |
| Marts (`mart_*`) | `curated` | MergeTree table | BI-ready datasets joining staging views — the stable contract for dashboards |

Staging views handle CDC semantics: for each primary key, they select the latest event by `ts_ms` and `_ingested_at`, excluding deletes (`op != 'd'`). This deterministic logic correctly handles initial snapshots, incremental changes, and replay scenarios.

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
make dbt-build
```

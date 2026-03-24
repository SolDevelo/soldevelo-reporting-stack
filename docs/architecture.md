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
  └─▶ Debezium CDC (Kafka Connect plugin)
        └─▶ Kafka (KRaft, no ZooKeeper)
              └─▶ ClickHouse
                    ├─▶ raw landing (append-only, for debug/replay/backfill)
                    └─▶ curated marts (BI contract — dashboards query only these)
                          ├─▶ dbt Core transformations
                          │     └─▶ Airflow orchestration
                          └─▶ Superset / Power BI
```

## ClickHouse raw landing pattern

For each CDC topic, the platform creates:

| Table | Engine | Purpose |
|---|---|---|
| `raw.kafka_<topic>` | Kafka Engine | Consumes JSON CDC events from Kafka |
| `raw.events_<topic>` | MergeTree | Append-only storage (90-day TTL default) |
| `raw.mv_<topic>` | Materialized View | Routes Kafka → MergeTree |

Each event stores the full Debezium envelope as JSON strings: `op`, `ts_ms`, `before`, `after`, `source`, `transaction`. The dbt layer (Task 4) parses these into typed columns and reconstructs current-state rows.

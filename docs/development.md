# Development Guide

This guide covers verification, debugging, and the developer workflow for contributing to the reporting-stack platform.

## Verification targets

Each target verifies a specific layer. Run them in order — each depends on the previous.

| Target | What it checks |
|---|---|
| `make verify-services` | Kafka, Kafka Connect, Apicurio, Kafka UI, ClickHouse are healthy |
| `make verify-cdc` | Debezium connector is RUNNING, CDC topics exist |
| `make verify-ingestion` | ClickHouse databases exist, events tables have rows |
| `make verify-dbt` | dbt build succeeds, curated mart tables have rows |

Or run all at once via `make setup` (idempotent — also re-registers the connector and re-inits ClickHouse). dbt is run separately via `make dbt-build` or `make verify-dbt`.

### verify-services

Checks each platform service is reachable via HTTP health endpoints.

Manual checks:

```bash
# Kafka broker
docker compose --env-file .env -f compose/docker-compose.yml exec kafka \
  kafka-broker-api-versions.sh --bootstrap-server localhost:9092

# Kafka Connect REST API
curl -s http://localhost:${CONNECT_PORT:-8083}/connectors

# Apicurio Registry
curl -s http://localhost:${APICURIO_PORT:-8085}/health

# Kafka UI
curl -s http://localhost:${KAFKA_UI_PORT:-9080}/ | head -5

# ClickHouse
curl -s http://localhost:${CLICKHOUSE_PORT:-8123}/ping
```

### verify-cdc

Checks the Debezium connector is RUNNING and at least one CDC topic exists.

Connector management:

```bash
make register-connector    # create or update connector config
make connector-status      # show connector + task status
make delete-connector      # remove connector (cleanup)
```

The connector template is loaded from `${ANALYTICS_CORE_PATH}/connect/` (default: `examples/olmis-analytics-core/connect/`). Environment variables in the JSON are substituted at registration time via `envsubst`.

#### Serialization

Messages use JSON converters (not Avro) for ClickHouse compatibility. ClickHouse has documented issues with Apicurio's AvroConfluent endpoint. Apicurio remains in the stack for schema governance if other consumers need Avro.

#### Table allowlist

The default allowlist (`SOURCE_PG_TABLE_ALLOWLIST` in `.env`) captures a small set of tables. To add tables:

1. Update `SOURCE_PG_TABLE_ALLOWLIST` in `.env`
2. Add the tables to the PostgreSQL publication (see [source-db-setup.md](source-db-setup.md))
3. Re-register: `make register-connector`
4. Re-init ClickHouse: `make clickhouse-init`

### ClickHouse raw landing configuration

The raw landing layer has several optional settings (all have sensible defaults):

| Variable | Default | Description |
|---|---|---|
| `RAW_KAFKA_TOPICS` | derived from `SOURCE_PG_TABLE_ALLOWLIST` | Explicit comma-separated list of Kafka topic names to ingest |
| `RAW_TTL_DAYS` | `90` | Retention period in days for `raw.events_*` tables. Set to `0` to disable TTL |
| `CLICKHOUSE_HOST_EXTERNAL` | `localhost` | Override `CLICKHOUSE_HOST` for host-side scripts (useful for remote ClickHouse deployments) |

TTL is applied per-table at creation time. Changing `RAW_TTL_DAYS` only affects newly created tables — existing tables retain their original TTL. To update TTL on existing tables, run:

```bash
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "ALTER TABLE raw.events_<table_name> MODIFY TTL toDateTime(_ingested_at) + INTERVAL <days> DAY"
```

#### Error handling

The Kafka Engine tables use `kafka_handle_error_mode = 'stream'`, which routes deserialization errors to the `_error` virtual column instead of stalling the consumer. The Materialized View filters these with `WHERE length(_error) = 0`, so malformed messages are silently skipped.

There is currently no dead-letter queue (DLQ) for failed records. To check for deserialization errors, query the Kafka Engine table directly:

```bash
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT _error, count() FROM raw.kafka_<table_name> WHERE length(_error) > 0 GROUP BY _error FORMAT Pretty"
```

> **Note:** The Kafka Engine table is a virtual consumer — querying it consumes messages. Use this only for diagnostics, not regular monitoring.

### verify-ingestion

Runs `clickhouse-init` (idempotent), then checks each `raw.events_*` table for row counts.

Manual ClickHouse queries:

```bash
# Check row counts
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT name, total_rows FROM system.tables WHERE database = 'raw' AND name LIKE 'events_%' FORMAT Pretty"

# Query a specific table
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT op, count() FROM raw.events_openlmis_referencedata_programs GROUP BY op FORMAT Pretty"

# Parse JSON payload
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT JSONExtractString(after, 'name') as name FROM raw.events_openlmis_referencedata_programs LIMIT 5 FORMAT Pretty"
```

### verify-dbt

Runs `dbt build` (deps + models + tests) via Docker, then checks that curated mart tables exist with rows.

```bash
make dbt-build      # run dbt build only
make verify-dbt     # run dbt build + verify curated marts
```

#### dbt architecture

The platform provides a **runner project** (`dbt/`) with generic macros. Adopter packages provide domain-specific models via dbt's local package mechanism:

```
dbt/                          # Platform runner project
  dbt_project.yml             # Runner config
  profiles.yml                # ClickHouse connection (env-var driven)
  packages.yml                # Generated: loads core + extension packages
  macros/                     # Platform macros (CDC helpers, schema override)
  Dockerfile                  # dbt-core + dbt-clickhouse image

examples/olmis-analytics-core/dbt/   # Example core package
  dbt_project.yml             # Package config
  models/staging/             # Current-state views from raw CDC events
  models/marts/               # Curated tables (BI contract)
```

Models are materialized in the `curated` ClickHouse database:
- **Staging** (`stg_*`): views that reconstruct current state from CDC events using `row_number()` + JSON extraction
- **Marts** (`mart_*`): MergeTree tables that join staging views into BI-ready datasets

Manual ClickHouse queries for curated data:

```bash
# List curated marts and row counts
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT name, total_rows FROM system.tables WHERE database = 'curated' FORMAT Pretty"

# Query a mart
curl -s "http://localhost:8123/" --user "default:changeme" \
  --data-binary "SELECT facility_name, geographic_zone_name FROM curated.mart_facility_directory LIMIT 5 FORMAT Pretty"
```

## Source database setup

See [source-db-setup.md](source-db-setup.md) for configuring the adopter's PostgreSQL database for CDC, including:
- Publication and heartbeat table setup
- WAL retention safety (`max_slot_wal_keep_size`)
- Network connectivity options
- Slot invalidation recovery

## Developer workflow

1. Make changes to platform code
2. `make build` to rebuild any modified Docker images
3. `make up` to apply compose changes
4. `make setup` to re-configure (idempotent)
5. Run the relevant `make verify-*` to verify

## Implementation plan

See [implementation-plan.md](implementation-plan.md) for the full task breakdown (Tasks 3–10).

# Development Guide

This guide covers verification, debugging, and the developer workflow for contributing to the reporting-stack platform.

## Verification targets

Each target verifies a specific layer. Run them in order — each depends on the previous.

| Target | What it checks |
|---|---|
| `make verify-services` | Kafka, Kafka Connect, Kafka UI, ClickHouse are healthy |
| `make verify-cdc` | Debezium connector is RUNNING, CDC topics exist |
| `make verify-ingestion` | ClickHouse databases exist, events tables have rows |
| `make verify-dbt` | dbt build succeeds, curated mart tables have rows |
| `make verify-airflow` | Airflow webserver/scheduler healthy, platform_refresh DAG registered |
| `make verify-superset` | Superset healthy, database/dataset/chart/dashboard imported |

Or run all at once via `make setup` (idempotent — re-registers the connector, re-inits ClickHouse, rebuilds dbt marts, and re-imports Superset assets).

### verify-services

Checks each platform service is reachable via HTTP health endpoints.

Manual checks:

```bash
# Kafka broker
docker compose --env-file .env -f compose/docker-compose.yml exec kafka \
  kafka-broker-api-versions.sh --bootstrap-server localhost:9092

# Kafka Connect REST API
curl -s http://localhost:${CONNECT_PORT:-8083}/connectors

# Kafka UI
curl -s http://localhost:${KAFKA_UI_PORT:-9080}/ | head -5

# ClickHouse
curl -s http://localhost:${CLICKHOUSE_PORT:-8123}/ping
```

### verify-cdc

Checks the Debezium connector is RUNNING, at least one CDC topic exists, and CDC streaming is active (heartbeat offset advancing). The streaming check takes ~12 seconds — it records the Kafka heartbeat topic offset, waits one heartbeat cycle, and verifies the offset advanced. This catches silent failures like an empty publication or a stale replication slot that other checks would miss.

Connector management:

```bash
make register-connector    # create or update connector config
make connector-status      # show connector + task status
make delete-connector      # remove connector (cleanup)
```

The connector template is loaded from `${ANALYTICS_CORE_PATH}/connect/` (default: `examples/olmis-analytics-core/connect/`). Environment variables in the JSON are substituted at registration time via `envsubst`.

#### Serialization

Messages use JSON converters (not Avro) for ClickHouse compatibility. JSON is natively supported by ClickHouse's Kafka engine and human-readable in Kafka UI. Schema evolution (column changes, new enum values) is caught by dbt tests (accepted_values, not_null) rather than a schema registry.

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

### verify-airflow

Checks that the Airflow webserver and scheduler are healthy, and that the `platform_refresh` DAG is registered.

#### Airflow architecture

Airflow runs with LocalExecutor (no Celery/Redis). Services:

| Service | Purpose |
|---|---|
| `airflow-db` | PostgreSQL 16 metadata database |
| `airflow-init` | One-shot: DB migrations + admin user creation |
| `airflow-scheduler` | Executes DAG tasks (has Docker socket access) |
| `airflow-webserver` | Web UI at `http://localhost:8080` |

The `platform_refresh` DAG runs on a schedule (default: `@hourly`):

1. **check_freshness** — queries ClickHouse `max(_ingested_at)` for all raw event tables. Skips if data is older than `FRESHNESS_MAX_AGE_MINUTES` (default: 60).
2. **dbt_build** — runs `scripts/dbt/build.sh` via BashOperator (Docker-in-Docker).
3. **dbt_test** — runs `scripts/dbt/test.sh` via BashOperator.

#### Docker-in-Docker setup

The Airflow scheduler invokes dbt by running `docker run` via the host Docker socket. This requires:

1. Docker socket mounted: `/var/run/docker.sock` (done in compose)
2. `REPORTING_HOST_ROOT` set in `.env` to the **host** path of this repo (Docker resolves paths on the host, not inside the container)

Without `REPORTING_HOST_ROOT`, the DAG's dbt tasks will fail because `docker build` and `docker run` volume mounts resolve against the host filesystem.

#### Fernet key

Airflow requires a Fernet key for encryption. Generate one:

```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
```

Set it in `.env` as `AIRFLOW__CORE__FERNET_KEY`.

### verify-superset

Checks that Superset is healthy and that assets have been imported. **Prerequisite**: run `make superset-import` before this verification will pass — unlike other services, Superset starts empty and assets must be explicitly imported.

What it checks:
- Superset health endpoint reachable
- API authentication works (JWT via `/api/v1/security/login`)
- At least one database, dataset, and chart registered
- Dashboard "OLMIS Requisition Overview" exists

Manual API checks:

```bash
# Get an API token
TOKEN=$(curl -sf -X POST -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"changeme","provider":"db","refresh":true}' \
  http://localhost:8088/api/v1/security/login \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# List databases
curl -sf -H "Authorization: Bearer $TOKEN" http://localhost:8088/api/v1/database/ \
  | python3 -c "import sys,json; [print(f'  {d[\"database_name\"]} ({d[\"backend\"]})') for d in json.load(sys.stdin)['result']]"

# List dashboards
curl -sf -H "Authorization: Bearer $TOKEN" http://localhost:8088/api/v1/dashboard/ \
  | python3 -c "import sys,json; [print(f'  {d[\"dashboard_title\"]}') for d in json.load(sys.stdin)['result']]"
```

#### Superset architecture

Superset runs as three containers:

| Service | Purpose |
|---|---|
| `superset-db` | PostgreSQL 16 metadata database |
| `superset-init` | One-shot: DB migrations + admin user creation |
| `superset` | Web application at `http://localhost:8088` |

The custom Dockerfile (`superset/Dockerfile`) extends Apache Superset 6.0.0 with the `clickhouse-connect` driver, a guest-permissions init script, and the Superset Embedded SDK JS. The platform `superset_config.py` configures the metadata database, feature flags, and — when `SUPERSET_EMBEDDING_ORIGINS` is set — CORS, CSP (`frame-ancestors`), and guest token authentication for embedded dashboards. All secrets come from environment variables, never from the image.

#### Assets-as-code workflow

Superset dashboards, charts, datasets, and database connections are stored as **unzipped YAML** files in the analytics package's `superset/assets/` directory. This is the source of truth — the Superset metadata DB is the runtime store.

The change workflow:

1. **Author** in the Superset UI (create/edit charts and dashboards interactively)
2. **Export** from the Superset UI or API (produces a ZIP of YAML files)
3. **Unzip and commit** the YAML files to the analytics package repository via PR
4. **Import** in target environments using `make superset-import`

The import script (`scripts/superset/import-assets.sh`) ZIPs the YAML directory at runtime and imports via the `superset import-dashboards` CLI. The orchestrating script (`scripts/superset/import-all.sh`) then patches ClickHouse database credentials and embedded dashboard `allowed_domains` from environment variables (`CLICKHOUSE_PASSWORD`, `SUPERSET_EMBEDDING_ORIGINS`). This ensures credentials and environment-specific config never appear in Git.

Import order: platform assets (optional) → core package → extension packages (layered, additive).

For a step-by-step guide on creating new charts and dashboards, see [usage-guide.md](usage-guide.md#add-a-superset-chartdashboard).

## Analytics packages

### Package loading

The platform supports two modes for loading analytics packages:

**Local mode** (default): `ANALYTICS_CORE_PATH` points to a filesystem directory. Used during development with the built-in examples.

**Git mode**: `ANALYTICS_CORE_GIT_URL` + `ANALYTICS_CORE_GIT_REF` trigger Git-based loading. dbt uses its native `git:` package support. For connector config and Superset assets, run `make package-fetch` which clones repos to `.packages/`.

### Package validation

`make package-validate` enforces the extend-only rule for extensions:
- No `connect/` directory in extensions
- No dbt model name collisions with core
- No Superset UUID collisions with core

Run this before deploying extension packages to catch violations early.

### manifest.yaml

Every package must include a `manifest.yaml` at its root with fields: `name`, `type` (core/extension), `platform_version`, `description`, and `includes` (list of component types). See [architecture.md](architecture.md#manifestyaml) for the schema.

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

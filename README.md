# reporting-stack

A reusable, open-source reporting platform maintained by SolDevelo. It connects to any adopter's PostgreSQL database via CDC and delivers analytics through a standardized pipeline. OpenLMIS/OLMIS is the first reference adopter, but the platform itself is project-agnostic.

## Architecture summary

| Layer | Technology | Owner |
|---|---|---|
| Source | PostgreSQL (external, adopter-owned) | Adopter |
| Ingestion | Debezium CDC via Kafka Connect | Platform |
| Transport | Apache Kafka (KRaft) | Platform |
| Schema governance | Apicurio Registry | Platform |
| Analytics store | ClickHouse (raw landing + curated marts) | Platform |
| Transformations | dbt Core (ClickHouse adapter) | Platform + Packages |
| Orchestration | Apache Airflow | Platform |
| Visualization | Apache Superset (default); Power BI optional | Platform + Packages |
| Monitoring | Platform observability (planned) | Platform |

### Key architecture principles

- **CDC from DB, not API polling**: captures changes directly from PostgreSQL WAL. Removes dependency on API permissions, eliminates sync race conditions, and ensures data completeness.
- **Separation of concerns**: ingestion (Debezium/Kafka), storage/query (ClickHouse), transformations (dbt), orchestration (Airflow), and visualization (Superset) are independent layers.
- **Raw landing as immutable event log**: append-only storage of all CDC events with metadata. Enables debugging, replay, and targeted backfills. Subject to retention/TTL policies.
- **Curated marts are the BI contract**: dashboards and BI tools (Superset, Power BI) connect only to curated marts, never to raw CDC tables. This provides a stable interface that survives ingestion/transformation changes.
- **Recoverability**: raw landing layer allows rebuilding curated marts after logic fixes without re-ingesting from source.
- **Data quality as a first-class feature**: minimum test suite required on all curated marts — integrity (`not_null`, `unique`), relationships (FK checks), accepted values (enumerations/status fields), freshness SLAs, and reconciliation (counts/sums between staging and marts). If critical tests fail, dashboards should be treated as potentially stale.
- **Superset assets as code**: dashboards/charts/datasets stored as unzipped YAML in Git (source of truth), not as UI-only state. Database credentials must never be stored in Git — inject at deploy time via environment variables. Change workflow: author in UI → export YAML from controlled environment → commit to appropriate repo → PR review → automated import.
- **Use current, supported component versions**: avoid reintroducing legacy maintenance risks. Especially relevant for Superset (upgrade to current release) and supporting components (Kafka, Debezium, ClickHouse).

### Platform vs adopter responsibilities

The **platform** (this repo) provides infrastructure, runtime composition, scripts, and generic tooling. **Adopters** provide domain-specific reporting logic via analytics packages:

- **Core package** (required): Debezium connector config, dbt models/tests/seeds, Superset assets-as-code
- **Extension packages** (optional, additive): additional dbt marts and Superset dashboards

Extensions may only **add** new assets. They must not modify core models/dashboards or change ingestion contracts (extend-only rule).

### Package contract

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

Packages are loaded via local paths (development) or pinned Git refs (production).

## Repository structure

```
compose/           Docker Compose files (platform services)
connect/           Kafka Connect image, platform scripts/templates
clickhouse/        Init SQL scripts and ClickHouse configuration
dbt/               dbt runner project + platform macros
airflow/           Airflow configuration and DAGs
superset/          Superset configuration and platform assets
registry/          Apicurio Schema Registry config
scripts/           Helper, operational, and verification scripts
docs/              Architecture docs and operational notes
examples/          Reference analytics packages (OLMIS core + Malawi extension)
```

## Prerequisites

- Docker Engine + Docker Compose plugin
- Network access to the adopter's PostgreSQL database
- PostgreSQL configured for logical replication (see Step 2)

## Quick start

```bash
cp .env.example .env    # edit with your values
make up                 # start the stack
make ps                 # check service status
make logs               # tail logs
make down               # stop the stack
make reset              # stop and wipe all volumes
```

## Makefile targets

| Target | Description |
|---|---|
| `up` | Start all services |
| `down` | Stop all services |
| `ps` | Show running services |
| `logs` | Tail logs (use `SVC=<name>` to filter) |
| `restart` | Restart services (use `SVC=<name>` to filter) |
| `reset` | Stop services and wipe all volumes |
| `lint` | Run linters (placeholder) |
| `verify` | Run verification checks (placeholder) |
| `build` | Build/rebuild service images (or `SVC=<name>`) |
| `register-connector` | Register/update the Debezium CDC connector |
| `connector-status` | Show connector and task status |
| `delete-connector` | Delete the CDC connector |
| `clickhouse-init` | Initialize ClickHouse databases and raw landing tables |

## Step-by-step verification

### Step 1 — Base platform services

Start the stack and verify all four services are healthy:

```bash
cp .env.example .env
make up
# wait ~60s for services to stabilize, then:
make step1
```

Or run checks manually:

```bash
# Kafka broker (via docker exec)
docker compose --env-file .env -f compose/docker-compose.yml exec kafka \
  kafka-broker-api-versions.sh --bootstrap-server localhost:9092

# Kafka Connect REST
curl -s http://localhost:${CONNECT_PORT:-8083}/connectors

# Apicurio Registry
curl -s http://localhost:${APICURIO_PORT:-8085}/health

# Kafka UI
curl -s http://localhost:${KAFKA_UI_PORT:-9080}/ | head -5
```

Service UIs:

| Service | Default URL |
|---|---|
| Kafka UI | http://localhost:9080 |
| Kafka Connect REST | http://localhost:8083 |
| Apicurio Registry | http://localhost:8085 |

### Step 2 — Debezium PostgreSQL CDC

#### PostgreSQL prerequisites

The source PostgreSQL database must be configured for logical replication:

```sql
-- postgresql.conf (or ALTER SYSTEM)
wal_level = logical
max_replication_slots = 4     -- at least 1 for Debezium
max_wal_senders = 4

-- Create a publication for the tables Debezium will capture
CREATE PUBLICATION dbz_publication FOR TABLE
  referencedata.facilities,
  referencedata.programs,
  referencedata.geographic_zones,
  requisition.requisitions,
  requisition.requisition_line_items;

-- (Optional) heartbeat table to prevent WAL bloat during idle periods
CREATE TABLE IF NOT EXISTS public.reporting_heartbeat (
  id  INT PRIMARY KEY DEFAULT 1,
  ts  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Grant replication privileges to the Debezium user
ALTER ROLE openlmis WITH REPLICATION;
```

Restart PostgreSQL after changing `wal_level`.

#### Register the connector

```bash
# Edit .env with your actual SOURCE_PG_* values, then:
make register-connector

# Check status
make connector-status
```

#### Verify

```bash
make step2
```

This checks that:
- The connector is in `RUNNING` state with at least one active task
- At least one CDC topic (prefixed with `$DEBEZIUM_TOPIC_PREFIX`) exists in Kafka

#### Connector management

```bash
make register-connector    # create or update connector config
make connector-status      # show connector + task status
make delete-connector      # remove connector (cleanup)
```

#### Serialization

Key and value serialization uses **Apicurio Registry Avro converters**. Schemas are auto-registered in Apicurio on first message. The converter JARs are baked into the Kafka Connect image via `connect/Dockerfile`. Schema governance configs (naming conventions, compatibility rules) should be stored in Git under `registry/` and applied to Apicurio at startup.

#### Table allowlist

The default allowlist (`SOURCE_PG_TABLE_ALLOWLIST` in `.env`) captures a small set of tables. Expand it as needed — the connector config is re-applied via `make register-connector`.

### Step 3 — ClickHouse raw landing

Initialize ClickHouse databases and create raw landing tables for CDC topics:

```bash
make clickhouse-init
```

This creates for each CDC topic:
- `raw.kafka_<topic>` — Kafka engine table (consumer)
- `raw.events_<topic>` — MergeTree storage table (append-only landing, 90-day TTL)
- `raw.mv_<topic>` — Materialized View routing Kafka → MergeTree

Verify data is flowing:

```bash
make step3
```

Service UIs:

| Service | Default URL |
|---|---|
| ClickHouse HTTP | http://localhost:8123 |

### Steps 4–8 (not yet implemented)

See the [implementation plan](docs/implementation-plan.md) for detailed task specifications.

## Implementation status

| Task | Status |
|---|---|
| 0–2. Base platform + Debezium CDC | Complete |
| 2.5. Folder restructure for platform + packages model | Complete |
| 3. ClickHouse + raw landing ingestion | Complete |
| 4. dbt transformations | Planned |
| 5. Airflow orchestration | Planned |
| 6. Superset + assets-as-code | Planned |
| 7. Package system formalization | Planned |
| 8. Extension example (Malawi) | Planned |
| 9. Bootstrap, backfill, slot recovery | Post-MVP |
| 10. Monitoring and alerting | Post-MVP |

## Environment configuration

Copy `.env.example` to `.env` and fill in the values. See the example file for all available variables.

Key variable groups:
- `SOURCE_PG_*` — source PostgreSQL connection
- `DEBEZIUM_*` — CDC connector settings
- `KAFKA_*` — Kafka broker configuration
- `ANALYTICS_CORE_PATH` — path to the core analytics package (default: `examples/olmis-analytics-core`)
- `ANALYTICS_EXTENSIONS_PATHS` — comma-separated paths to extension packages
- Service ports: `CONNECT_PORT`, `APICURIO_PORT`, `KAFKA_UI_PORT`, `CLICKHOUSE_*`, `SUPERSET_*`, `AIRFLOW_*`

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[AGPL-3.0](LICENSE)

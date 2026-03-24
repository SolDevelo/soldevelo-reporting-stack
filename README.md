# reporting-stack

A reusable, open-source reporting platform maintained by SolDevelo. It connects to any adopter's PostgreSQL database via CDC and delivers analytics through a standardized pipeline. OpenLMIS/OLMIS is the first reference adopter, but the platform itself is project-agnostic.

## Architecture

| Layer | Technology |
|---|---|
| Source | PostgreSQL (external, adopter-owned) |
| Ingestion | Debezium CDC via Kafka Connect |
| Transport | Apache Kafka (KRaft) |
| Schema governance | Apicurio Registry |
| Analytics store | ClickHouse (raw landing + curated marts) |
| Transformations | dbt Core (ClickHouse adapter) |
| Orchestration | Apache Airflow |
| Visualization | Apache Superset (default); Power BI optional |

For architecture principles and design rationale, see [docs/architecture.md](docs/architecture.md).

## Prerequisites

- Docker Engine + Docker Compose plugin
- Network access to the adopter's PostgreSQL database
- PostgreSQL configured for logical replication — see [docs/source-db-setup.md](docs/source-db-setup.md)

## Getting started

### 1. Configure

```bash
cp .env.example .env
```

Edit `.env` with your database connection details:

```env
SOURCE_PG_HOST=olmis-db          # database hostname
SOURCE_PG_PORT=5432
SOURCE_PG_DB=open_lmis           # database name
SOURCE_PG_USER=postgres
SOURCE_PG_PASSWORD=p@ssw0rd
```

The remaining defaults work for the built-in OLMIS example package. See [Environment configuration](#environment-configuration) for all variables.

### 2. Start services

```bash
make up
```

This starts Kafka, Kafka Connect, Apicurio Registry, Kafka UI, and ClickHouse. Services need ~90 seconds to fully initialize (Kafka Connect is the slowest).

### 3. Set up the pipeline

```bash
make setup
```

This single command:
- Waits for all services to be healthy
- Registers the Debezium CDC connector (captures changes from your database)
- Creates ClickHouse databases and raw landing tables
- Verifies the full pipeline is working

### Troubleshooting

If `make setup` fails, run verification individually to find which layer is broken:

```bash
make verify-services    # Kafka, Connect, Apicurio, Kafka UI
make verify-cdc         # Debezium connector + CDC topics
make verify-ingestion   # ClickHouse raw landing tables
```

## Service UIs

| Service | Default URL | Purpose |
|---|---|---|
| Kafka UI | http://localhost:9080 | Browse topics, messages, consumer groups |
| Kafka Connect REST | http://localhost:8083 | Connector management API |
| Apicurio Registry | http://localhost:8085 | Schema governance |
| ClickHouse HTTP | http://localhost:8123 | Query analytics data |

## Common operations

```bash
make up          # start all services
make down        # stop all services
make ps          # show running services
make logs        # tail all logs (SVC=kafka to filter)
make setup       # configure pipeline (idempotent, run after make up)
make reset       # stop and wipe all data volumes
make build       # rebuild Docker images after changes
```

## Environment configuration

Copy `.env.example` to `.env`. Key variable groups:

| Group | Variables | Purpose |
|---|---|---|
| Source database | `SOURCE_PG_HOST`, `SOURCE_PG_PORT`, `SOURCE_PG_DB`, `SOURCE_PG_USER`, `SOURCE_PG_PASSWORD` | PostgreSQL connection for CDC |
| Debezium | `SOURCE_PG_SLOT_NAME`, `SOURCE_PG_PUBLICATION`, `DEBEZIUM_TOPIC_PREFIX`, `SOURCE_PG_TABLE_ALLOWLIST` | CDC connector settings |
| Service ports | `KAFKA_EXTERNAL_PORT`, `CONNECT_PORT`, `APICURIO_PORT`, `KAFKA_UI_PORT`, `CLICKHOUSE_PORT` | Host port mappings |
| Analytics packages | `ANALYTICS_CORE_PATH`, `ANALYTICS_EXTENSIONS_PATHS` | Package loading (see below) |

## Analytics packages

Adopters provide domain-specific reporting logic via **analytics packages** — separate repositories containing Debezium connector config, dbt models, and Superset dashboards. The platform loads packages at runtime.

- **Core package** (required): baseline connector config + models + dashboards
- **Extension packages** (optional): additive-only — new models and dashboards, no modifications to core

The built-in OLMIS example packages under `examples/` demonstrate the expected structure. Set `ANALYTICS_CORE_PATH` in `.env` to point to your package (default: `examples/olmis-analytics-core`).

For the full package contract and governance model, see [docs/architecture.md](docs/architecture.md).

## Repository structure

```
compose/           Docker Compose service definitions
connect/           Kafka Connect Dockerfile
clickhouse/        ClickHouse init SQL and configuration
dbt/               dbt runner project + platform macros
airflow/           Airflow configuration and DAGs
superset/          Superset configuration and platform assets
scripts/           Operational and setup scripts
docs/              Architecture, development guide, runbooks
examples/          Reference analytics packages (OLMIS core + Malawi extension)
```

## Implementation status

| Task | Status |
|---|---|
| Base platform (Kafka, Connect, Apicurio, Kafka UI) | Complete |
| Debezium CDC ingestion | Complete |
| ClickHouse raw landing | Complete |
| dbt transformations | Planned |
| Airflow orchestration | Planned |
| Superset + assets-as-code | Planned |
| Package system formalization | Planned |
| Extension example (Malawi) | Planned |
| Bootstrap, backfill, slot recovery | Post-MVP |
| Monitoring and alerting | Post-MVP |

See [docs/implementation-plan.md](docs/implementation-plan.md) for detailed task specifications.

## Documentation

| Document | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Architecture principles, design rationale, package contract |
| [docs/development.md](docs/development.md) | Developer workflow, step-by-step verification, debugging |
| [docs/source-db-setup.md](docs/source-db-setup.md) | Source database configuration, WAL safety, network setup |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Implementation task breakdown (Tasks 3–10) |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[AGPL-3.0](LICENSE)

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
- **Minimum resources:** ~5 GB RAM for the reporting stack alone; ~7 GB when running alongside a typical adopter application. Disk usage depends on CDC volume and raw landing TTL (default 90 days)

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

Generate and set a Fernet key (required for Airflow encryption):

```bash
python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"
# Paste the output as AIRFLOW__CORE__FERNET_KEY in .env
```

Set `REPORTING_HOST_ROOT` to the **absolute host path** of this repository (required for Airflow to invoke dbt):

```env
REPORTING_HOST_ROOT=/home/user/workspace/openlmis-reporting
```

The remaining defaults work for the built-in OLMIS example package. See [Environment configuration](#environment-configuration) for all variables.

> **Note:** The default credentials in `.env.example` (`changeme`, `admin`) are for local development only. For production deployments, change all passwords and see [Security considerations](#security-considerations).

### 2. Create the shared network (standalone deployments only)

If you are **not** using the openlmis-ref-distro overlay (which creates this network automatically), create it manually:

```bash
docker network create reporting-shared
```

This network allows Kafka Connect to reach the source database. If using the ref-distro overlay, skip this step.

### 3. Start services

```bash
make up
```

This starts Kafka, Kafka Connect, Apicurio Registry, Kafka UI, ClickHouse, Airflow, and Superset. Services need ~90 seconds to fully initialize (Kafka Connect is the slowest).

### 4. Set up the pipeline

```bash
make setup
```

This single command configures the entire pipeline end-to-end:
- Waits for all services to be healthy
- Registers the Debezium CDC connector (captures changes from your database)
- Creates ClickHouse databases and raw landing tables
- Waits for initial data to arrive
- Builds curated marts with dbt (analytics-ready tables)
- Imports Superset dashboards from the analytics package
- Verifies the full pipeline

### 5. View dashboards

Open [http://localhost:8088](http://localhost:8088) and log in with the default credentials (`admin` / `changeme`). You should see the **OLMIS Requisition Overview** dashboard with data from your source database.

After the initial setup, Airflow refreshes the curated marts automatically on a schedule (default: hourly). To refresh manually at any time, run `make dbt-build`. See [Data freshness](#data-freshness) for configuration.

### Troubleshooting

If `make setup` fails, run verification individually to find which layer is broken:

```bash
make verify-services    # Kafka, Connect, Apicurio, Kafka UI, ClickHouse
make verify-cdc         # Debezium connector + CDC topics
make verify-ingestion   # ClickHouse raw landing tables
make verify-dbt         # dbt build + curated mart tables
make verify-airflow     # Airflow health + DAG registration
make verify-superset    # Superset health + dashboard exists
make verify-packages    # Full package pipeline: validate + build + import + dashboards
```

Individual steps can also be run manually if needed:

```bash
make dbt-build          # rebuild curated marts
make superset-import    # re-import Superset dashboards
```

## Service UIs

| Service | Default URL | Purpose |
|---|---|---|
| Kafka UI | http://localhost:9080 | Browse topics, messages, consumer groups |
| Kafka Connect REST | http://localhost:8083 | Connector management API |
| Apicurio Registry | http://localhost:8085 | Schema governance |
| ClickHouse HTTP | http://localhost:8123 | Query analytics data |
| Airflow | http://localhost:8080 | DAG management and monitoring |
| Superset | http://localhost:8088 | Dashboards and analytics |

## Common operations

```bash
make up          # start all services
make down        # stop all services
make ps          # show running services
make logs        # tail all logs (SVC=kafka to filter)
make setup       # full pipeline setup: CDC + ClickHouse + dbt + Superset (idempotent)
make dbt-build   # run dbt transformations (builds curated marts)
make reset       # ⚠ DESTRUCTIVE: stop and delete all data (Kafka, ClickHouse, Airflow)
make build       # rebuild Docker images after changes
make superset-import  # import Superset dashboards from analytics packages
```

## Environment configuration

Copy `.env.example` to `.env`. Key variable groups:

| Group | Variables | Purpose |
|---|---|---|
| Source database | `SOURCE_PG_HOST`, `SOURCE_PG_PORT`, `SOURCE_PG_DB`, `SOURCE_PG_USER`, `SOURCE_PG_PASSWORD` | PostgreSQL connection for CDC |
| Debezium | `SOURCE_PG_SLOT_NAME`, `SOURCE_PG_PUBLICATION`, `DEBEZIUM_TOPIC_PREFIX`, `SOURCE_PG_TABLE_ALLOWLIST` | CDC connector settings |
| Service ports | `KAFKA_EXTERNAL_PORT`, `CONNECT_PORT`, `APICURIO_PORT`, `KAFKA_UI_PORT`, `CLICKHOUSE_PORT`, `AIRFLOW_PORT`, `SUPERSET_PORT` | Host port mappings (change if conflicts with other services) |
| Data freshness | `AIRFLOW_REFRESH_SCHEDULE`, `FRESHNESS_MAX_AGE_MINUTES` | How often dashboards refresh (see below) |
| Airflow | `AIRFLOW__CORE__FERNET_KEY`, `AIRFLOW_DB_PASSWORD`, `AIRFLOW_ADMIN_USER`, `AIRFLOW_ADMIN_PASSWORD` | Orchestrator settings |
| Superset | `SUPERSET_ADMIN_USER`, `SUPERSET_ADMIN_PASSWORD`, `SUPERSET_SECRET_KEY`, `SUPERSET_PORT`, `SUPERSET_DB_PASSWORD` | Visualization layer credentials and settings |
| Analytics packages (local) | `ANALYTICS_CORE_PATH`, `ANALYTICS_EXTENSIONS_PATHS` | Filesystem package paths (development) |
| Analytics packages (Git) | `ANALYTICS_CORE_GIT_URL`, `ANALYTICS_CORE_GIT_REF`, `ANALYTICS_EXTENSION_GIT_URLS`, `ANALYTICS_EXTENSION_GIT_REFS`, `GIT_TOKEN` | Git-based package loading (production) |

## Analytics packages

Adopters provide domain-specific reporting logic via **analytics packages** — separate repositories containing Debezium connector config, dbt models, and Superset dashboards. The platform loads packages at runtime.

- **Core package** (required): baseline connector config + models + dashboards
- **Extension packages** (optional): additive-only — new models and dashboards, no modifications to core

**Local mode** (development): set `ANALYTICS_CORE_PATH` in `.env` to a filesystem path (default: `examples/olmis-analytics-core`).

**Git mode** (production): set `ANALYTICS_CORE_GIT_URL` and `ANALYTICS_CORE_GIT_REF` in `.env`. dbt fetches models directly from Git. Run `make package-fetch` to download connector config and Superset assets.

Run `make package-validate` to enforce extend-only rules on extension packages.

For the full package contract and governance model, see [docs/architecture.md](docs/architecture.md).

## Data freshness

Changes in the source database reach ClickHouse raw landing within **seconds** (real-time CDC). However, **dashboard data** depends on how often dbt rebuilds the curated marts.

Airflow runs the `platform_refresh` DAG on a schedule controlled by `AIRFLOW_REFRESH_SCHEDULE` in `.env`:

| Setting | Meaning |
|---|---|
| `*/15 * * * *` | Every 15 minutes — for operational dashboards |
| `@hourly` (default) | Every hour — good balance for general reporting |
| `@daily` | Once per day — minimal resource usage |

To refresh data immediately after a change, run `make dbt-build` or trigger the DAG from the Airflow UI (`http://localhost:8080`).

**When dbt tests fail**, the Airflow DAG run is marked as failed but dashboards continue serving the previous data (marts are not corrupted). Check the Airflow UI for failed runs — red indicates a data quality issue that should be investigated. There is currently no automated alerting (planned for post-MVP).

For a detailed breakdown of latency at each pipeline layer, see [docs/architecture.md](docs/architecture.md#data-freshness-and-refresh-latency).

## Security considerations

**Default credentials are for development only.** Before any production or internet-exposed deployment, change all passwords in `.env`: `SOURCE_PG_PASSWORD`, `CLICKHOUSE_PASSWORD`, `AIRFLOW_DB_PASSWORD`, `AIRFLOW_ADMIN_PASSWORD`, `SUPERSET_ADMIN_PASSWORD`, and `SUPERSET_SECRET_KEY`.

**Service ports are exposed on the host.** By default, Kafka UI (9080), Kafka Connect (8083), ClickHouse (8123), Airflow (8080), and Superset (8088) are accessible on all interfaces. In production, restrict access with firewall rules or bind to localhost only. Port variables (e.g., `AIRFLOW_PORT`) control host mappings — changing them does not affect inter-container communication.

**Docker socket access.** The Airflow scheduler mounts `/var/run/docker.sock` to invoke dbt via Docker. This grants the container root-equivalent access to the Docker daemon. This is standard for CI/CD-style workloads but should be understood: a compromised Airflow scheduler could control any container on the host. In production, consider using a Docker socket proxy or running Airflow outside of Docker.

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
| dbt transformations | Complete |
| Airflow orchestration | Complete |
| Superset + assets-as-code | Complete |
| Package system formalization | Complete |
| Extension example (Malawi) | Complete |
| Bootstrap, backfill, slot recovery | Post-MVP |
| Monitoring and alerting | Post-MVP |

See [docs/implementation-plan.md](docs/implementation-plan.md) for detailed task specifications.

## Documentation

| Document | Purpose |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Architecture principles, design rationale, package contract |
| [docs/development.md](docs/development.md) | Developer workflow, step-by-step verification, debugging |
| [docs/source-db-setup.md](docs/source-db-setup.md) | Source database configuration, WAL safety, network setup |
| [docs/usage-guide.md](docs/usage-guide.md) | Practical how-tos: add tables, dbt models, Superset charts, author packages |
| [docs/end-to-end-test.md](docs/end-to-end-test.md) | End-to-end test: OLMIS change → CDC → ClickHouse → dbt → Superset |
| [docs/implementation-plan.md](docs/implementation-plan.md) | Implementation task breakdown (Tasks 3–10) |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[AGPL-3.0](LICENSE)

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a reusable, open-source reporting platform ("reporting-stack") maintained by SolDevelo. It connects to any adopter's PostgreSQL database via CDC and delivers analytics through: Debezium → Kafka → ClickHouse → dbt → Airflow → Superset. The platform is project-agnostic; OpenLMIS/OLMIS is the first reference adopter.

The key architectural separation: this repo is the **platform** (infrastructure + runtime + generic tooling). Adopters provide domain-specific logic via **analytics packages** (core + optional extensions). Architecture principles and design rationale are documented in the README.

## Common Commands

```bash
# Start/stop all services
make up          # docker compose up -d
make down        # docker compose down
make reset       # stop + wipe all volumes

# Observe
make ps          # running services
make logs        # tail all logs (SVC=kafka to filter)

# Debezium connector management
make register-connector   # create/update CDC connector
make connector-status     # show connector + task status
make delete-connector     # remove connector

# Verification (sequential — step1 before step2)
make step1       # verify Kafka, Connect, Apicurio, Kafka UI health
make step2       # verify Debezium connector + CDC topics exist
```

`make lint` and `make verify` exist as placeholders but are not yet implemented.

## Architecture

```
Adopter PostgreSQL (external)
  └─▶ Debezium CDC (Kafka Connect plugin)
        └─▶ Kafka (KRaft, no ZooKeeper)
              ├─▶ Apicurio Registry (Avro schema governance)
              └─▶ ClickHouse (planned)
                    ├─▶ raw landing (append-only, for debug/replay/backfill)
                    └─▶ curated marts (BI contract — dashboards query only these)
                          ├─▶ dbt Core transformations (planned)
                          │     └─▶ Airflow orchestration (planned)
                          └─▶ Superset / Power BI (planned)
```

Key services in `compose/docker-compose.yml`: `kafka`, `kafka-connect`, `apicurio`, `kafka-ui`. All have healthchecks. `kafka-connect` depends on both `kafka` and `apicurio` being healthy before starting.

## Platform + Packages Model

- **Platform** (this repo): infrastructure, compose, scripts, dbt runner, generic macros
- **Core package** (adopter-owned, required): Debezium connector config, dbt models/tests, Superset assets
- **Extension packages** (optional, additive-only): new dbt marts + Superset dashboards; must not modify core or change ingestion

Example packages live in `examples/` as permanent reference documentation:
- `examples/olmis-analytics-core/` — reference core package for OpenLMIS
- `examples/olmis-analytics-malawi/` — reference extension package

Packages are loaded via `ANALYTICS_CORE_PATH` and `ANALYTICS_EXTENSIONS_PATHS` env vars.

## Configuration

All configuration is environment-driven (`.env` file, templated from `.env.example`). The Debezium connector config uses `envsubst` for variable substitution at registration time.

Key env var groups: `SOURCE_PG_*` (source database), `DEBEZIUM_*` (CDC settings), `KAFKA_*`, `ANALYTICS_CORE_PATH`, `ANALYTICS_EXTENSIONS_PATHS`, service ports.

## Code Conventions

- **Shell scripts**: bash strict mode (`set -euo pipefail`), source `.env` from repo root, use `python3 -c` for JSON processing
- **Indentation**: 2 spaces default; 4 spaces for Python; tabs for Makefile (per `.editorconfig`)
- **SQL**: lowercase keywords, 2-space indent
- **Python**: PEP 8
- Contributions follow `CONTRIBUTING.md`: conventional commits, feature branches, AGPL-3.0

## Testing Environment (openlmis-ref-distro)

The sibling repository at `../openlmis-ref-distro` (branch `reporting-stack-integration`) is the production-like testing environment for this platform. It runs the full OpenLMIS system with a PostgreSQL database configured for CDC.

**This is a live integration target, not a read-only reference.** When implementing tasks from the implementation plan, you should update the ref-distro integration as needed — for example, adding new services to the compose overlay, updating the init SQL with new tables, or adjusting network configuration.

Key files in ref-distro:
- `docker-compose.reporting-stack.yml` — compose overlay that creates the `reporting-shared` network and runs the DB init container
- `reporting-stack/init-db.sql` — idempotent CDC SQL (publication, heartbeat, replication role)
- `reporting-stack/wait-and-init.sh` — init container entrypoint (waits for Flyway, runs SQL)

How to run both stacks together:

```bash
# 1. Start ref-distro with reporting overlay
cd ../openlmis-ref-distro
docker compose -f docker-compose.yml -f docker-compose.reporting-stack.yml up -d --build --force-recreate

# 2. Start reporting stack (this repo)
cd ../openlmis-reporting
cp .env.example .env  # set SOURCE_PG_HOST=olmis-db, SOURCE_PG_USER=postgres, SOURCE_PG_PASSWORD=p@ssw0rd
make up

# 3. Verify
make step1
make register-connector
make step2
```

Networking: the `reporting-shared` Docker network is created by the ref-distro overlay. The reporting stack's `kafka-connect` joins it as external. The DB is accessible as `olmis-db` on this network.

**Important:** `kafka-connect` needs `KAFKA_HEAP_OPTS: "-Xms256m -Xmx512m"` to avoid OOM when running alongside the full OLMIS stack (which consumes ~28GB RAM).

## Implementation Status

Tasks 0–2.5 (base platform + Debezium CDC + folder restructure) are complete. The full implementation plan (Tasks 3–10) is documented in `docs/implementation-plan.md`. Tasks 3–8 are MVP scope; Tasks 9–10 are post-MVP.

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
| `register-connector` | Register/update the Debezium CDC connector |
| `connector-status` | Show connector and task status |
| `delete-connector` | Delete the CDC connector |

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

### Steps 3–8 (not yet implemented)

See [Implementation plan](#implementation-plan) below.

---

## Implementation plan

Tasks 0–2 (base platform + Debezium CDC) are complete. The plan below covers MVP delivery (Tasks 2.5–8) and post-MVP stages (Tasks 9–10).

Each task from 3 onward incrementally builds the OLMIS example packages under `examples/` alongside the platform components they exercise. By the end of Task 6, `examples/olmis-analytics-core/` is a complete working reference package. Tasks 7–8 formalize the package system and add the extension example.

### Task 2.5 — Restructure folders for platform + packages model

Move from the current flat layout to the platform + packages structure described above. This is a non-breaking refactor — Tasks 1–2 must remain functional. Also fixes several code quality issues from Tasks 1–2.

Requirements:

**Folder restructure:**

1. Create `examples/olmis-analytics-core/` with barebones structure (`connect/`, `dbt/`, `superset/`, `manifest.yaml`, `README.md`).
2. Move the OLMIS-specific connector JSON (`connect/connectors/openlmis-postgres-cdc.json`) into `examples/olmis-analytics-core/connect/`.
3. Keep in `connect/` only the platform Dockerfile and scripts.
4. Add env var `ANALYTICS_CORE_PATH` (default: `examples/olmis-analytics-core`) and update connector registration scripts to read from `${ANALYTICS_CORE_PATH}/connect/`.
5. Create `examples/olmis-analytics-malawi/` with barebones placeholder structure.

**Script fixes (from Task 1–2 review):**

6. In `scripts/connect/register-connector.sh`: restrict `envsubst` to only the named connector variables (prevents mangling passwords or values containing `$`). Use `envsubst '${SOURCE_PG_HOST} ${SOURCE_PG_PORT} ...'` instead of bare `envsubst`.
7. In `scripts/connect/register-connector.sh`: replace the hardcoded `/tmp/connect-register-response.json` with `mktemp`; add a `trap` to clean up on exit.
8. In `scripts/connect/register-connector.sh`: exit with error if JSON parsing fails instead of falling back to a hardcoded connector name.
9. In the connector JSON template: qualify the heartbeat query with explicit schema — `INSERT INTO public.reporting_heartbeat ...`.
10. In the connector JSON template: add a comment explaining that `decimal.handling.mode: "double"` is a deliberate trade-off for ClickHouse compatibility (lossy for financial NUMERIC columns; `"precise"` would be safer but produces strings).

**Compose and Makefile fixes:**

11. Define an explicit Docker network (`reporting`) in `compose/docker-compose.yml` and attach all services to it. This prepares for the growing topology (ClickHouse, Airflow, Superset each with their own DBs).
12. Fix the `reset` Makefile target: remove the `down` dependency so `docker compose down` is not called twice. The `reset` body should run `$(COMPOSE_CMD) down -v --remove-orphans` directly.
13. Add a `build` Makefile target (`$(COMPOSE_CMD) build`) for forcing image rebuilds after Dockerfile changes.

**Environment configuration:**

14. Update `.env.example`: replace the `# --- Country Config Extension ---` block with `ANALYTICS_CORE_PATH` and `ANALYTICS_EXTENSIONS_PATHS` variables using the new naming convention.
15. Add a comment in `.env.example` noting that `KAFKA_BOOTSTRAP_SERVERS` is used by platform scripts (ClickHouse init, etc.), not by the compose services directly.

**Verification:**

16. `make step1` and `make step2` still pass.

Deliverables: updated folder structure, fixed scripts, updated compose/Makefile, updated `.env.example`, no loss of existing functionality.

### Task 3 — ClickHouse + raw landing ingestion

Add ClickHouse to the platform and implement raw landing ingestion from Kafka. The raw landing layer is append-only, storing CDC events with metadata for debugging, replay, and backfill.

Fixed choices:
- ClickHouse official image
- Kafka Engine + Materialized Views into MergeTree
- Two databases: `raw` (landing) and `curated` (marts, populated later by dbt)
- Raw tables store event payload + metadata in a generic, project-agnostic way

Design notes:
- Raw landing is append-only — treat it as an immutable event log within retention policy.
- CDC events include inserts, updates, and deletes. The raw layer stores all of them; the "current state" reconstruction happens in dbt (Task 4), not here.
- Plan for retention/TTL policies on raw tables (configurable per deployment).
- DLQ (dead-letter queue) topics in Kafka are recommended for records that fail deserialization or ingestion.

Requirements:

1. Add `clickhouse` service to compose on the `reporting` network (from Task 2.5) with persistent volume + healthcheck.
2. Create `clickhouse/init/` SQL that:
   - Creates databases `raw`, `curated`
   - Implements a generic raw ingestion pattern:
     - `raw.kafka_<topic>` Kafka Engine tables
     - `raw.events_<topic>` MergeTree storage tables
     - Materialized Views from Kafka tables to storage tables
3. Provide a config-driven topic list (env var `RAW_KAFKA_TOPICS` or small config file under `clickhouse/config/`) initialized with at least one OLMIS CDC topic from Task 2.
4. Provide scripts:
   - `scripts/clickhouse/init.sh` (idempotent initialization)
   - `scripts/clickhouse/verify-ingestion.sh` (checks tables exist + row count)
5. Add Step 3 verification to README.

Deliverables: compose service + init SQL + scripts + verification.

### Task 4 — dbt transformations (platform runner + OLMIS example models)

Implement dbt in a platform + package model. The platform provides a runner project and generic macros. Adopter packages provide domain-specific models.

Fixed choices:
- dbt Core + ClickHouse adapter
- dbt runner project in this repo loads additional model paths from packages
- No copying files into the runner; use additive model paths via `ANALYTICS_CORE_PATH` and `ANALYTICS_EXTENSIONS_PATHS`

Design notes:
- Staging models must handle CDC semantics: raw events contain inserts, updates, and deletes. Use deterministic "current-state" logic to reconstruct the latest row version per primary key.
- Use incremental models where appropriate to reduce compute on large tables.
- Curated marts are the stable contract for BI tools — column renames or type changes are breaking changes.
- Data quality tests are mandatory (see architecture principles above). At minimum: integrity, relationships, accepted values, freshness, reconciliation.

Requirements:

1. Create `dbt/` as the runner project with:
   - `dbt_project.yml` configured to include model paths from packages
   - Platform macros for parsing CDC payloads (generic helpers)
2. Add `scripts/dbt/build.sh` that:
   - Runs `dbt deps` if packages.yml is used
   - Runs `dbt build` (default selector: models from the configured core package)
3. Add example OLMIS dbt content in `examples/olmis-analytics-core/dbt/`:
   - One staging model reading from a ClickHouse raw events table
   - One mart model in `curated` (simple projection or aggregation)
   - At least two tests (not_null + unique or a simple reconciliation check)
   - Data quality tests per architecture principles: integrity, relationships, accepted values
4. Ensure `.gitignore` covers dbt artifacts: `dbt/target/`, `dbt/dbt_packages/`, `dbt/logs/`, `dbt/.user.yml` (and equivalent paths under `examples/`).
5. `scripts/verify/step4.sh`: runs `dbt build`, confirms the curated mart exists and has rows.
6. Add Step 4 verification to README.

Deliverables: dbt runner + platform macros + example OLMIS models/tests + scripts.

### Task 5 — Airflow orchestration

Add Airflow as the platform orchestrator for refresh pipelines (see architecture principles 4.8).

Fixed choices:
- Airflow with PostgreSQL metadata DB
- LocalExecutor baseline
- One platform DAG: freshness check → dbt build → dbt test

Requirements:

1. Add Airflow services to compose: `airflow-webserver`, `airflow-scheduler`, `airflow-db`.
2. Create DAG `airflow/dags/platform_refresh.py`:
   - Parameterized via env vars: `DBT_SELECT` (default: core models), `FRESHNESS_MAX_AGE_MINUTES`
   - Freshness gate: checks ClickHouse raw ingestion timestamp before proceeding
   - Uses BashOperator to call `scripts/dbt/build.sh`
   - Runs dbt tests as a separate downstream task
3. `scripts/verify/step5.sh`: ensures Airflow UI is reachable, triggers DAG, checks success.
4. Add Step 5 verification to README.

Deliverables: compose services + DAG + scripts.

### Task 6 — Superset + assets-as-code

Add Superset as the default visualization layer with deterministic, layered asset imports (see architecture principles 9).

Fixed choices:
- Superset with PostgreSQL metadata DB
- Assets stored as unzipped YAML in Git (not ZIP), with `metadata.yaml` at bundle root
- Import order: platform assets (optional) → core → extensions
- BI tools connect only to curated marts, never raw CDC tables

Design notes:
- **Secrets policy**: database credentials must not be stored in Git. Database connection objects are imported without passwords and patched after import via environment-specific configuration.
- **Source of truth**: Git repositories hold the canonical asset definitions. The Superset metadata DB is the runtime store. Any changes made in the Superset UI must be exported to YAML and committed via PR.
- **Import must be deterministic and repeatable**: every environment can be rebuilt from Git sources alone, eliminating manual UI drift.
- Use a current, supported Superset release.

Requirements:

1. Add Superset services to compose: `superset`, `superset-db`. Use a current, supported Superset release (not a legacy version).
2. Custom Dockerfile under `superset/` with ClickHouse driver (`clickhouse-connect` pip package).
3. Implement scripts:
   - `scripts/superset/init.sh` (migrations + admin user)
   - `scripts/superset/import-assets.sh` (imports a single asset path)
   - `scripts/superset/import-all.sh` (imports in order: platform → core → extensions)
4. Add example OLMIS Superset assets in `examples/olmis-analytics-core/superset/assets/`:
   - Dataset on the curated mart from Task 4
   - One chart + one dashboard
5. `scripts/verify/step6.sh`: verifies Superset is reachable, imports assets, confirms dashboard exists via API.
6. Add Step 6 verification to README.

Deliverables: compose services + Superset config + import scripts + example assets.

### Task 7 — Package system formalization (manifest, Git sync, validation)

Formalize the package loading mechanism so the platform can consume packages from local paths or pinned Git repositories (see architecture principles 8.5).

By this point, `examples/olmis-analytics-core/` is a complete working package (connector + dbt + Superset). This task adds the formal contract and production-grade loading.

Requirements:

1. Define and document `manifest.yaml` schema:
   - Fields: `name`, `type` (core|extension), `platform_version` (compatibility), `includes` (list of component types)
2. Add `manifest.yaml` to `examples/olmis-analytics-core/`.
3. Add a documented package contract in `examples/olmis-analytics-core/README.md`.
4. Implement `package-sync` service (one-shot container) for Git-based loading:
   - Env vars: `ANALYTICS_CORE_GIT_URL`, `ANALYTICS_CORE_GIT_REF`, `ANALYTICS_EXTENSION_GIT_URLS` (comma-separated), `ANALYTICS_EXTENSION_GIT_REFS` (comma-separated), `GIT_TOKEN` (optional)
   - Clones to a shared named volume under `/packages/core` and `/packages/extensions/<n>/`
   - Writes `.sync_complete` with resolved commit SHAs
5. Implement `scripts/packages/validate.sh` (extend-only enforcement):
   - Fails if an extension defines a dbt model with the same name as a core model
   - Fails if an extension Superset asset UUID collides with a core UUID
   - Fails if an extension includes `connect/` (extensions must not change ingestion)
6. Update platform scripts to respect `ANALYTICS_CORE_PATH` and `ANALYTICS_EXTENSIONS_PATHS` consistently across connector registration, dbt, and Superset import.
7. Add Step 7 verification to README.

Deliverables: manifest schema + package-sync service + validation scripts + documentation.

### Task 8 — Extension example (olmis-analytics-malawi)

Create a reference extension package demonstrating the extend-only model (see architecture principles 8.3–8.4).

Requirements:

1. Create `examples/olmis-analytics-malawi/` with:
   - `manifest.yaml` (type: extension)
   - `dbt/`: one new mart model derived from the core mart (e.g., filtered view or aggregation), with tests
   - `superset/assets/`: dataset on the Malawi mart, one chart, one dashboard
   - `README.md` explaining it's an example extension
2. `scripts/verify/step8.sh` supporting two modes:
   - **Local mode**: `ANALYTICS_CORE_PATH=examples/olmis-analytics-core`, `ANALYTICS_EXTENSIONS_PATHS=examples/olmis-analytics-malawi`
   - **Git mode**: uses package-sync to fetch from local Git repos under `examples/`
   - Both modes: run validation → dbt build → confirm Malawi mart exists → import Superset assets → confirm Malawi dashboard exists
3. Add Step 8 verification to README.

Deliverables: extension example package + verification script + documentation.

---

### Post-MVP stages

#### Task 9 — Bootstrap, backfill, and slot invalidation recovery

This task covers three related scenarios that share the same tooling: initial load for new deployments, targeted backfill for specific tables/date ranges, and recovery after a replication slot invalidation.

**Why this matters:** When the reporting stack goes down for an extended period, PostgreSQL's `max_slot_wal_keep_size` (configured in Task 2 setup) will invalidate the replication slot to protect disk space. Changes that occurred during the gap are lost from the CDC stream. The data still exists in the source PostgreSQL — it just wasn't captured. This task provides the tooling and runbooks to handle that recovery, as well as the initial bootstrap for new country deployments.

**Scenario A — New country deployment (initial load):**

CDC captures incremental changes, but countries need to load historical/current state into ClickHouse before CDC starts.

Standard approach: bulk snapshot → load into ClickHouse → start CDC.

**Scenario B — Slot invalidation recovery:**

When a replication slot is invalidated (WAL limit exceeded while reporting stack was down):

1. The CDC stream has a gap — some changes were not captured
2. The source database still has the correct current state
3. Recovery requires re-establishing a consistent baseline in ClickHouse

Recovery approach: delete failed connector → drop orphaned slot → export current state from PostgreSQL → import into ClickHouse → re-register connector (creates new slot, starts fresh CDC stream) → rebuild curated marts with dbt → run reconciliation tests.

**Scenario C — Targeted backfill:**

Rebuild specific tables or date ranges without a full re-snapshot (e.g., after a dbt model fix, after adding new tables to the publication).

**Requirements:**

1. Provide `scripts/bootstrap/export.sh`:
   - Exports baseline data from PostgreSQL using `pg_dump` or `COPY`
   - Supports full export (all captured tables) and targeted export (specific tables or schemas)
   - Records a watermark timestamp for the export

2. Provide `scripts/bootstrap/import.sh`:
   - Imports baseline into ClickHouse `raw` tables with the watermark timestamp
   - Idempotent — safe to re-run (uses the watermark to avoid duplicates)
   - Supports both full and targeted import

3. Provide `scripts/bootstrap/recover-slot.sh`:
   - Automated recovery procedure for slot invalidation:
     - Deletes the failed Debezium connector
     - Drops the orphaned replication slot from PostgreSQL
     - Runs export → import for all captured tables
     - Re-registers the connector (triggers new slot + initial snapshot)
     - Waits for snapshot to complete
     - Triggers dbt rebuild of curated marts
     - Runs reconciliation tests
   - Logs each step for audit trail

4. Document three runbooks in `docs/`:
   - `docs/runbook-initial-load.md` — new country deployment
   - `docs/runbook-slot-recovery.md` — slot invalidation recovery (step-by-step, including how to detect invalidation, expected downtime, and verification)
   - `docs/runbook-backfill.md` — targeted table/date range backfill

5. Add an Airflow DAG (`airflow/dags/backfill.py`) for orchestrated backfill that can be triggered manually with parameters (table list, date range).

6. Support targeted backfills by date range or domain/topic.

**Design notes:**

- The ClickHouse raw landing layer (append-only) makes recovery straightforward: import the snapshot data alongside existing CDC events. The dbt staging models use deterministic "current-state" logic (latest version per primary key), so overlapping data resolves correctly.
- Reconciliation tests (counts/sums between source PostgreSQL and curated marts) are critical after any recovery to confirm data integrity.
- Consider adding Debezium incremental snapshot support (via a signal table) as an alternative to full re-snapshot for large databases. This allows chunk-by-chunk re-reading without blocking.

This task is planned for the second stage, after the MVP platform is validated with real OLMIS data. However, the basic slot recovery procedure (delete connector → drop slot → re-register) works immediately with the current setup — it just triggers Debezium's built-in full snapshot rather than the optimized export/import path.

#### Task 10 — Monitoring and alerting

Add platform observability to detect pipeline failures and data staleness early (see architecture principles 4.10).

Recommended monitoring signals:
- Debezium connector health + replication slot lag
- Kafka consumer lag / throughput
- ClickHouse ingestion freshness (max raw event timestamp)
- Airflow DAG failures and runtimes
- dbt test failures and freshness SLA breaches

This task is post-MVP. Specific tooling choices (Prometheus, Grafana, etc.) to be decided during implementation.

---

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

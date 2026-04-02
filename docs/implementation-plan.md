# Implementation Plan

Tasks 0–2.5 (base platform + Debezium CDC + folder restructure) are complete. The plan below covers MVP delivery (Tasks 3–8) and post-MVP stages (Tasks 9–10).

Each task from 3 onward incrementally builds the OLMIS example packages under `examples/` alongside the platform components they exercise. By the end of Task 6, `examples/olmis-analytics-core/` is a complete working reference package. Tasks 7–8 formalize the package system and add the extension example.

## MVP scope

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

1. Add `clickhouse` service to compose on the `reporting` network with persistent volume + healthcheck.
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
- Data quality tests are mandatory (see architecture principles in README). At minimum: integrity, relationships, accepted values, freshness, reconciliation.

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

Add Airflow as the platform orchestrator for refresh pipelines.

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

Add Superset as the default visualization layer with deterministic, layered asset imports.

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

### Task 6.5 — Documentation (Getting Started, Superset docs, usage guides)

With Tasks 0–6 complete the full pipeline works end-to-end, but the user-facing documentation has not kept pace. The README Getting Started flow stops at `make setup` (CDC + ClickHouse raw landing) — it does not mention `make dbt-build` or `make superset-import`, so a user following it cannot reach a working dashboard. Superset was added with scripts and verification but zero user-facing documentation. There are no practical guides for developers who want to build their own reporting on this platform.

This task goes here (before Task 7) because the README is broken now, and Task 7's "documented package contract" requirement will be cleaner to deliver if baseline docs already exist.

Fixed choices:
- README stays simple — zero-to-dashboard quickstart for adopters, links to deeper docs
- New `docs/usage-guide.md` for practical developer how-tos (separate from `development.md` which is platform-contributor-focused)
- `make setup` runs the full pipeline end-to-end: CDC + ClickHouse + dbt build + Superset import + verification
- Usage guide references existing example files by path rather than duplicating code

Requirements:

1. Fix README Getting Started flow (`README.md`):
   - Add Step 5: `make dbt-build` (transforms raw CDC events into curated marts)
   - Add Step 6: `make superset-import` (loads dashboards from the analytics package)
   - Add Step 7: direct the user to `http://localhost:8088` with default credentials
   - Add `Superset` row to the Environment configuration table
   - Add `docs/usage-guide.md` to the Documentation index table

2. Add verify-superset section to `docs/development.md`:
   - Add `verify-superset` to the verification targets table
   - Document what it checks (health, API auth, database/dataset/chart/dashboard)
   - Add manual Superset API checks (list dashboards, datasets)
   - Add Superset architecture subsection: services, Dockerfile, assets-as-code workflow, secrets policy

3. Create `docs/usage-guide.md` with four practical how-to sections:
   - **Add a new source table end-to-end**: publication → allowlist → connector → ClickHouse → dbt staging → mart → Superset (10 steps)
   - **Add a dbt model**: staging pattern (ranked CTE, JSON extraction, CDC semantics), mart pattern (joins, MergeTree), required tests
   - **Add a Superset chart/dashboard**: author in UI → export → YAML structure → UUIDs → secrets policy → import → verify
   - **Author an analytics package**: directory structure, core vs extension, extend-only rule, env vars, testing

4. Expand `examples/olmis-analytics-core/README.md`:
   - Full file listing with one-line descriptions
   - Connector config, dbt model, and Superset asset overviews
   - "Customizing for your project" section

Deliverables: updated README + development guide + new usage guide + expanded package README.

### Task 7 — Package system formalization (manifest, validation, Git loading)

Formalize the package loading mechanism so the platform can consume packages from local paths or pinned Git repositories.

By this point, `examples/olmis-analytics-core/` is a complete working package (connector + dbt + Superset). This task adds the formal contract, validation, and production-grade Git loading.

Design decisions:
- **Use dbt's native package system for dbt models.** dbt already supports `git:` packages with pinned `revision:` in `packages.yml`. The platform generates this file dynamically from env vars. For production, `scripts/dbt/run.sh` generates `git:` entries (with `subdirectory: "dbt"`) instead of `local:` mounts. `dbt deps` handles cloning, caching, and version pinning — no custom sync service needed.
- **Lightweight Git fetch for non-dbt parts.** Connector config and Superset assets have no native package manager. A simple `scripts/packages/fetch.sh` shell script clones repos (shallow, pinned ref) to a local directory. No Docker service, no shared volume — just a script that runs before `register-connector` and `superset-import`.
- **No custom `package-sync` Docker service.** The original plan proposed a one-shot container with shared volumes. This is over-engineering: dbt has its own mechanism, and the remaining components (one JSON file + YAML assets) don't justify a custom container. A shell script is simpler, easier to debug, and has no container orchestration dependencies.
- **Local paths remain the default for development.** The `ANALYTICS_CORE_PATH` / `ANALYTICS_EXTENSIONS_PATHS` env vars still work for local development. Git loading is opt-in via `ANALYTICS_CORE_GIT_URL` / `ANALYTICS_CORE_GIT_REF`.

Requirements:

1. Define and document `manifest.yaml` schema:
   - Fields: `name`, `type` (core|extension), `platform_version` (compatibility), `includes` (list of component types: connect, dbt, superset)
2. Add `manifest.yaml` to `examples/olmis-analytics-core/`.
3. Update `scripts/dbt/run.sh` to support two modes:
   - **Local mode** (current): generates `local:` entries in `packages.yml` from `ANALYTICS_CORE_PATH` / `ANALYTICS_EXTENSIONS_PATHS`
   - **Git mode**: when `ANALYTICS_CORE_GIT_URL` is set, generates `git:` entries with `revision:` and `subdirectory: "dbt"`. dbt handles cloning.
4. Implement `scripts/packages/fetch.sh` for non-dbt Git loading:
   - Env vars: `ANALYTICS_CORE_GIT_URL`, `ANALYTICS_CORE_GIT_REF`, `ANALYTICS_EXTENSION_GIT_URLS` (comma-separated), `ANALYTICS_EXTENSION_GIT_REFS` (comma-separated), `GIT_TOKEN` (optional, for private repos)
   - Clones to `.packages/core/` and `.packages/extensions/<name>/` under the repo root
   - Sets `ANALYTICS_CORE_PATH` and `ANALYTICS_EXTENSIONS_PATHS` for downstream scripts
   - Shallow clone (`--depth 1 --branch <ref>`) for speed
5. Implement `scripts/packages/validate.sh` (extend-only enforcement):
   - Fails if an extension defines a dbt model with the same name as a core model
   - Fails if an extension Superset asset UUID collides with a core UUID
   - Fails if an extension includes `connect/` (extensions must not change ingestion)
6. Update `scripts/connect/register-connector.sh` and `scripts/superset/import-all.sh` to use paths set by `fetch.sh` when in Git mode.
7. Add `.packages/` to `.gitignore`.
8. Update documentation:
   - `docs/architecture.md`: update package contract section with manifest schema and the two loading modes (local vs Git)
   - `docs/usage-guide.md`: update "Author an analytics package" section with manifest.yaml details, Git loading instructions, and validation
   - `examples/olmis-analytics-core/README.md`: add manifest.yaml documentation
   - `docs/development.md`: add package verification section
   - `README.md`: add package loading to Environment configuration table (Git URL env vars), update Analytics packages section

Deliverables: manifest schema + fetch script + validation script + updated dbt runner + documentation.

### Task 8 — Extension example (olmis-analytics-malawi)

Create a reference extension package demonstrating the extend-only model.

Requirements:

1. Create `examples/olmis-analytics-malawi/` with:
   - `manifest.yaml` (type: extension)
   - `dbt/`: one new mart model derived from the core mart (e.g., filtered view or aggregation), with tests
   - `superset/assets/`: dataset on the Malawi mart, one chart, one dashboard
   - `README.md` explaining it's an example extension
2. Verification script `scripts/verify/packages.sh` supporting two modes:
   - **Local mode**: `ANALYTICS_CORE_PATH=examples/olmis-analytics-core`, `ANALYTICS_EXTENSIONS_PATHS=examples/olmis-analytics-malawi`
   - **Git mode**: uses `fetch.sh` to fetch from local Git repos under `examples/`
   - Both modes: run validation → dbt build → confirm Malawi mart exists → import Superset assets → confirm Malawi dashboard exists
3. Update documentation:
   - `README.md`: add verification step for extension packages
   - `docs/usage-guide.md`: add "Create an extension package" worked example referencing Malawi
   - `examples/olmis-analytics-malawi/README.md`: explain it's an example extension with practical structure reference

Deliverables: extension example package + verification script + documentation.

### Task 8.5 — Pipeline stability and self-healing

Harden the reporting stack so it tolerates restarts, temporary disconnections, and startup ordering issues without manual intervention. Currently, if the source database restarts, Kafka Connect loses the connection, or the stacks start in the wrong order, the pipeline silently stops flowing and requires manual re-registration or script re-runs to recover.

This task should be completed before version upgrades (Tasks 8.1–8.4) so that upgrade-related failures are distinguishable from pre-existing stability issues.

**Phase A — Container restart policies and startup resilience:**

1. Add `restart: unless-stopped` to all long-running services in `compose/docker-compose.yml` (kafka, kafka-connect, kafka-ui, clickhouse, airflow-scheduler, airflow-webserver, superset).
2. Make `kafka-connect` tolerate late source DB availability — the Debezium connector already has retry settings, but if Connect itself starts before Kafka is fully ready or before the source DB is reachable, the connector registration can fail. Document that `make register-connector` is idempotent and safe to re-run.
3. Add a `make recover` target that re-runs the minimum steps to restore a broken pipeline: verify services → re-register connector (idempotent) → verify CDC → verify ingestion. This is the "something broke, fix it" command.

**Phase B — Connector auto-recovery:**

4. Add a connector health watchdog script (`scripts/connect/watchdog.sh`) that:
   - Polls connector status via `GET /connectors/{name}/status`
   - If any task is in `FAILED` state, restarts it via `POST /connectors/{name}/tasks/{id}/restart`
   - If the connector itself is missing (deleted or Connect restarted with lost state), re-registers it
   - Logs actions taken
5. Run the watchdog as a lightweight sidecar container or as a cron-style loop in the existing compose setup. Polling interval: 30s–60s.
6. Add Debezium connector config setting `errors.tolerance: all` with `errors.deadletterqueue.topic.name` for a DLQ topic, so poisoned messages don't block the pipeline.

**Phase C — Startup order independence:**

7. Remove the hard requirement that ref-distro must start before the reporting stack. The reporting stack should start cleanly even if the source DB is not yet available — services wait and retry rather than fail.
8. `kafka-connect` should handle "source DB not ready" gracefully: the connector registration fails but Connect itself stays healthy. The watchdog (from Phase B) re-attempts registration periodically.
9. Document the supported startup scenarios in `docs/development.md`:
   - Both stacks start together (normal)
   - Reporting stack starts first, source DB comes later (must work)
   - Source DB restarts while pipeline is running (must self-heal within retry window)

**Phase D — Operational documentation:**

10. Add `docs/operations.md` covering:
    - Normal operation: what to expect, how to verify the pipeline is healthy
    - Common failure scenarios and recovery steps:
      - Source DB restarted → connector retries automatically (5 min window), then watchdog re-registers if needed
      - Kafka Connect restarted → connectors auto-restore from internal topics; watchdog verifies
      - Full stack restart → `make recover` restores the pipeline
      - Replication slot invalidated → see Task 9 for full recovery
    - `make recover` usage
    - How to check if data is flowing: `make verify-cdc`, `make verify-ingestion`
    - Monitoring recommendations (replication slot lag, connector status, ClickHouse row counts)

**Requirements summary:**

| # | Deliverable | Purpose |
|---|---|---|
| 1 | Restart policies on all services | Survive container crashes |
| 2 | `make recover` target | One-command pipeline restoration |
| 3 | Connector watchdog script + container | Auto-restart failed tasks, re-register lost connectors |
| 4 | DLQ topic for poisoned messages | Prevent pipeline blockage from bad records |
| 5 | Startup order independence | Both stacks can start in any order |
| 6 | `docs/operations.md` | Runbook for common failure scenarios |

Deliverables: compose changes + watchdog script + Makefile target + operations documentation.

### Task 8.1 — Version upgrades: low-risk pins and patches

Pin unpinned dependencies and apply patch-level upgrades. No behavioral changes expected.

Requirements:

1. Pin Superset pip packages in `superset/Dockerfile`:
   - `clickhouse-connect==0.14.1`
   - `psycopg2-binary==2.9.11`
2. Pin PostgreSQL images: `postgres:16-alpine` → `postgres:16.13-alpine` for both `airflow-db` and `superset-db` (security patches).
4. Verify all services start and `make verify-services` passes.

Deliverables: updated Dockerfile + compose image tags. No config changes.

### Task 8.2 — Version upgrades: Kafka UI and ClickHouse

Replace the abandoned Kafka UI and upgrade ClickHouse to a supported LTS.

**Kafka UI**: the `provectuslabs/kafka-ui` project is abandoned (last release Apr 2024). The active fork is `kafbat/kafka-ui` (v1.4.2, Nov 2025). Environment variables are compatible — only the image name changes.

**ClickHouse**: 24.8 LTS is end-of-life. 25.8 is the current LTS line (Mar 2026). No breaking changes to Kafka engine DDL, JSONExtract functions, or `kafka_handle_error_mode = 'stream'`. Critical: ClickHouse 25.3+ ships librdkafka 2.8.0 which is required for Kafka 4.x protocol support (Task 8.3).

Requirements:

1. Replace `provectuslabs/kafka-ui:v0.7.2` with `kafbat/kafka-ui:v1.4.2` in compose. Environment variables stay the same.
2. Upgrade `clickhouse/clickhouse-server:24.8-alpine` to `clickhouse/clickhouse-server:25.8-alpine`.
3. Verify: Kafka UI connects and shows topics/consumers. ClickHouse Kafka engine tables consume correctly. `make verify-services && make verify-ingestion` passes.
4. Run full `make setup` to confirm end-to-end pipeline with new versions.

Deliverables: updated compose image tags + verification.

### Task 8.3 — Version upgrades: Kafka 4.x + Confluent Platform 8.x + Debezium 3.x

Upgrade the CDC pipeline to current major versions. These three components form a dependency chain and must be upgraded together:

- Kafka 4.2 is KRaft-only (ZooKeeper fully removed — already using KRaft)
- Confluent Platform 8.2 (`cp-kafka-connect`) ships JDK 21 and targets Kafka 4.2
- Debezium 3.4 requires Java 17+ (met by CP 8.2's JDK 21) and has no connector config key changes vs 2.x
- ClickHouse 25.3+ (from Task 8.2) has the librdkafka version needed for Kafka 4.x protocol

**Why upgrade now**: Kafka 3.x is in maintenance mode. Debezium 2.x receives only critical fixes. Starting the platform on soon-to-be-EOL versions creates upgrade debt. The migration is simpler now (single DAG, five tables) than after production adoption.

Requirements:

1. Replace the custom `soldevelo/kafka:3.7` image:
   - Evaluate using Confluent's `cp-kafka` image or building a new image based on the official Apache Kafka Docker image (available since Kafka 3.7+, `apache/kafka:4.2.0`).
   - Configure for KRaft single-node (already the current mode).
2. Upgrade `connect/Dockerfile`:
   - Base image: `confluentinc/cp-kafka-connect:8.2.0`
   - Debezium plugin: `3.4.2.Final` (PostgreSQL connector JARs)
3. Re-register the connector with `make register-connector` — no config key changes expected between Debezium 2.x and 3.x for the PostgreSQL connector.
4. Verify: `make verify-services && make verify-cdc && make verify-ingestion`. Confirm the CDC streaming check (heartbeat advancing) passes.
5. Update compose header comments with new version references.

Design notes:
- The connector config (`openlmis-postgres-cdc.json`) should not need changes — Debezium 3.x kept the same property names for the PostgreSQL connector.
- If Kafka UI (kafbat v1.4.2 from Task 8.2) does not yet support Kafka 4.x, monitor for a new release or accept a temporarily unhealthy Kafka UI until one ships.
- Test that ClickHouse Kafka engine consumer groups work correctly with the new broker.

Deliverables: new Kafka image + updated Connect Dockerfile + verified pipeline.

### Task 8.4 — Version upgrades: Airflow 3.x

Upgrade from Airflow 2.9.3 to 3.1.x. This is a major version with architectural changes but our usage is simple (one DAG, BashOperator, LocalExecutor).

**Breaking changes that affect us:**
- BashOperator moved to `airflow.providers.standard.operators.bash` (new import path)
- REST API moved from `/api/v1` to `/api/v2` (affects `verify-airflow` script)
- Health endpoint moved from `/health` to `/api/v2/monitor/health` (affects healthcheck in compose and verify script)
- `airflow users create` replaced by SimpleAuthManager config or optional FAB provider
- DAG imports: `from airflow.sdk` instead of `from airflow.models`
- Context variables: `execution_date` removed (use `logical_date`)
- Python 3.10+ required (currently using 3.12, so this is fine)

**Why upgrade now**: Airflow 2.x will reach EOL. Our DAG is simple — one file, three tasks, BashOperator only. Migrating now (before adding more DAGs in Tasks 9-10) minimizes the surface area of changes.

Requirements:

1. Update `airflow/Dockerfile`: base image `apache/airflow:3.1.8-python3.12` (or latest 3.1.x). Install `apache-airflow-providers-standard` for BashOperator.
2. Update `airflow/dags/platform_refresh.py`:
   - Change imports to `airflow.sdk` / `airflow.providers.standard`
   - Replace any deprecated context variables
3. Update compose `airflow-init` command:
   - Replace `airflow users create` with SimpleAuthManager config or install FAB provider
   - Verify `airflow db migrate` still works
4. Update compose healthchecks: `/health` → `/api/v2/monitor/health` for webserver.
5. Update `scripts/verify/airflow.sh`: all API calls from `/api/v1` to `/api/v2`, health endpoint path.
6. Update `docs/development.md` Airflow architecture section if service behavior changed.
7. Verify: `make verify-airflow` passes. Trigger `platform_refresh` DAG and confirm dbt runs.

Deliverables: updated Dockerfile + DAG + compose + verify script + docs.

---

## Post-MVP stages

### Task 9 — Bootstrap, backfill, and slot invalidation recovery

This task covers three related scenarios that share the same tooling: initial load for new deployments, targeted backfill for specific tables/date ranges, and recovery after a replication slot invalidation.

**Why this matters:** When the reporting stack goes down for an extended period, PostgreSQL's `max_slot_wal_keep_size` (configured in the ref-distro setup) will invalidate the replication slot to protect disk space. Changes that occurred during the gap are lost from the CDC stream. The data still exists in the source PostgreSQL — it just wasn't captured. This task provides the tooling and runbooks to handle that recovery, as well as the initial bootstrap for new country deployments.

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

### Task 10 — Monitoring and alerting

Add platform observability to detect pipeline failures and data staleness early.

Recommended monitoring signals:
- Debezium connector health + replication slot lag
- Kafka consumer lag / throughput
- ClickHouse ingestion freshness (max raw event timestamp)
- Airflow DAG failures and runtimes
- dbt test failures and freshness SLA breaches

This task is post-MVP. Specific tooling choices (Prometheus, Grafana, etc.) to be decided during implementation.

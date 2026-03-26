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

### Task 7 — Package system formalization (manifest, Git sync, validation)

Formalize the package loading mechanism so the platform can consume packages from local paths or pinned Git repositories.

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

Create a reference extension package demonstrating the extend-only model.

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

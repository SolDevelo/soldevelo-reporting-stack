# Plan: incremental dbt materialization + decoupled deploy

Status: **planned, not yet started** (2026-05-28). See `## Tracker` at the bottom.

## Why this exists

The reporting-stack today builds every curated mart with `materialized='table'`. Every `dbt build`/`dbt run` therefore **drops and rebuilds each mart from scratch**, scanning all of its upstream sources every time — including on routine `make setup` re-runs that change nothing.

This works fine for seed data. On the **Malawi dev** dataset (49 M raw CDC events, 28.8 M `requisition_line_items`, 13.8 M `stock_adjustment_reasons`) it doesn't. Specifically:

- `mart_stock_status` joins `requisition_line_items` (28.8 M) with every dimension and aggregates. Its build needed ~6.5 GiB on the smaller dev box; after the snapshot grew, it approached ClickHouse's `max_server_memory_usage` (~28 GiB on the resized r5.xlarge) and ClickHouse self-terminated gracefully, taking the deploy with it.
- Even when the build succeeds, **every** restart/redeploy re-runs it, wasting hours and risking the same crash again.
- `mart_adjustments` reads `stock_adjustment_reasons` (13.8 M rows) and will hit the same wall once it has real data.

Other adopters will have larger datasets than Malawi. The current model materialization choice is the structural blocker for production-grade deployments. This document is the plan to fix it.

## Goals

1. **Restarts and redeploys must be cheap and safe.** A `make setup` re-run on an unchanged stack should do near-zero work, not re-aggregate millions of rows.
2. **Routine refreshes are O(delta), not O(total).** Scheduled dbt runs process only new CDC events.
3. **The initial bootstrap is an explicit, planned step** — not something that hides inside the deploy flow and surprises operators.
4. **One bad mart can't crash the server** — query memory is capped per-query so failures are visible and contained.
5. **Adopters with 10× or 100× more data than Malawi can still deploy.**

## Non-goals

- Real-time / sub-minute freshness. Current schedule is `@hourly`; that stays.
- Slowly-Changing-Dimension-Type-2 history for dimensions. Out of scope; current "latest state" semantics are correct for the dashboards we have.
- Changing the CDC ingestion layer. raw is fine.
- Changing dashboards. Datasets/queries reference the same `curated.mart_*` names.

## Design — the chosen pattern

```
raw.events_* (CDC append-only, MergeTree)
       │
       ▼
curated.stg_*     ←  materialized=incremental (append), projects ts_ms as _cdc_ts
       │
       ▼
curated.mart_*    ←  materialized=table   for dimension-style / small marts
                  ←  materialized=incremental (delete+insert) for big aggregates
                       filtered with: _cdc_ts > (select max(_cdc_ts) from {{ this }})
       │
       ▼
Superset
```

**Watermark column:** every staging model exposes `_cdc_ts` (`toDateTime64(ts_ms / 1000, 3)`). Marts filter on it during incremental runs via `is_incremental()`.

**Deletes:** CDC `op='d'` events arrive in raw. Staging models keep them (don't filter). For incremental marts where deletes matter (e.g. `mart_facility_directory` *if* we made it incremental — we won't), we'd handle via either `op='d'` tombstoning or a periodic `--full-refresh`. For marts that stay as `table`, deletes are free.

**Why not "all incremental":** see `## Decisions` below. Short version: `table` is simpler, safer for dimensions, and correctness-free re late-arriving data. Promote to incremental only when forced by build cost.

## Phases

### Phase A — Audit (~½ day)

Walk every model in `examples/olmis-analytics-core/dbt/models/marts/` and `examples/olmis-analytics-malawi/dbt/models/marts/`. For each, classify:

| Question | Answer determines |
| --- | --- |
| What's the largest source it scans? | If <1 M rows → `table`. If multi-million → candidate for `incremental`. |
| Does it have a natural `unique_key` (PK, or composite)? | If no, incremental is harder; consider keeping as `table` or building a key. |
| Are source deletes meaningful to the dashboards? | If yes and frequent, needs explicit delete handling. |
| Is it a dimension (mirrors a source table) or an aggregate? | Dimensions stay `table`. |

**Deliverable:** a table in this doc, per mart × decision × watermark column × notes. Strong default for any mart whose largest scan is <1 M rows: stay as `table`.

Suspected outcomes (to be verified by the audit):

| Mart | Materialization | Reason |
| --- | --- | --- |
| `mart_facility_directory` | `table` | Dimension, mirrors `referencedata.facilities` (1666 rows). |
| `mart_requisition_summary` | `table` (probably) or `incremental` if scan cost surprises us | 1.2 M source rows; full rebuild may already be acceptable. |
| `mart_stock_status` | **incremental** | Scans 28.8 M `requisition_line_items`. Confirmed memory bomb. |
| `mart_adjustments` | **incremental** | Will scan 13.8 M `stock_adjustment_reasons`. |
| `mart_reporting_status` | `table` or **incremental** | Decide after audit (3.5 M `status_changes`). |
| `mart_non_reporting_facilities` | `table` | Derived from `mart_reporting_status`; small downstream. |
| `mart_logistics_summary` | `table` | Already small (49 rows). |
| `mart_malawi_*` | `table` | Read from already-built core marts; cheap. |

### Phase B — Staging watermark (~½ day)

Convert `stg_*` from `view` to `materialized='incremental'` with `incremental_strategy='append'`. Each `stg_X` carries:
- All projected columns from `raw.events_*`
- `_cdc_ts` (from Debezium `ts_ms`)
- `_cdc_op` (Debezium `op`: `r`/`c`/`u`/`d`)

`is_incremental()` filter: `where ts_ms > (select max(ts_ms) from {{ this }})`.

Effect: mart queries read from materialized staging tables, not raw, and have a stable watermark to filter on. Staging tables lag raw by at most one cycle (acceptable; dashboards aren't real-time).

### Phase C — Refactor the big marts (~1–2 days)

For each mart classified as incremental in Phase A:
1. Add `materialized='incremental'`, `unique_key`, `incremental_strategy='delete+insert'`.
2. Add `is_incremental()` block filtering `_cdc_ts > (select coalesce(max(_cdc_ts), toDateTime64(0, 3)) from {{ this }})`.
3. Decide deletion handling (most likely: source deletes are rare for these fact tables; rely on `--full-refresh` for the occasional full reconcile).
4. Verify side-by-side: build with `--full-refresh` then run twice incrementally; row counts and key columns should match a fresh full build.

### Phase D — Decouple `make setup` from initial dbt build (~½ day)

This is the structural fix to the deploy flow.

Split `scripts/setup.sh` so the deploy is fast and idempotent and the heavy data work is a separate, explicit step.

- **`make setup`** keeps: wait for Kafka Connect, register Debezium connector, init ClickHouse raw landing tables, import Superset dashboards, run the verify checks. **Removes** the unconditional `dbt build`. Safe to re-run any time.
- **`make initial-dbt-build`** (new target): runs `dbt run --full-refresh` once for a fresh deployment.
- The Jenkins deploy script calls only `make setup`.
- The Airflow `platform_refresh` DAG keeps running `dbt run` (now incremental) on schedule for the routine refresh.

Document the lifecycle in `docs/operations.md`:
- *Fresh deployment:* operator runs `make initial-dbt-build` once after the first `make setup` succeeds. May require temporary instance sizing for the one-time scan.
- *Redeploys / restarts:* `make setup` only. Cheap.
- *Routine refresh:* Airflow DAG. Cheap.

### Phase E — Robustness defaults (~½ day)

- **Pin `threads: 1`** in `dbt/profiles.yml` until dbt-clickhouse is upgraded — eliminates the SESSION_IS_LOCKED race we hit, and naturally limits peak memory.
  - Check upstream for a dbt-clickhouse release that fixes the session-id-per-thread issue; bump the pin in `dbt/Dockerfile` if available.
- **Per-query ClickHouse memory cap** in the dbt profile (`max_memory_usage`). Pick a value (e.g. 20 GiB) so a misbehaving query fails fast with `MEMORY_LIMIT_EXCEEDED` instead of nudging the server toward self-shutdown.
- **Airflow DAG hardening** in `airflow/dags/platform_refresh.py`: `max_active_runs=1`, retries with backoff, alert on consecutive failures.

### Phase F — Verify on Malawi dev + document (~½ day)

Use the existing Malawi dev box (or a clean clone of it) as the validation environment:
1. Fresh setup → `make setup` → confirm fast + no dbt build.
2. `make initial-dbt-build` → confirm completes and all marts populated.
3. Run `dbt run` (incremental) twice in a row → confirm second run is fast (only delta).
4. Trigger a Jenkins redeploy → confirm no rebuild, no mart damage, no failure.
5. Update `docs/operations.md` and `docs/architecture.md` with the new lifecycle + materialization decisions.

## Decisions (and why)

### Why not make every mart incremental "just in case"

Incremental trades complexity for performance. The costs are:
- **Late-arriving data risk**: if a source row's `_cdc_ts` is older than the current watermark when it arrives (out-of-order CDC, retroactive updates), the filter misses it.
- **Source deletes**: `delete+insert` strategy handles updates fine; source-side `DELETE`s become silently invisible without explicit handling.
- **Watermark drift**: bugs here are subtle and produce "missing rows" symptoms diagnosed months later.
- **Code/test complexity**: every incremental model has two code paths (`is_incremental()` true/false) that both must be tested.

Benefits show up only when full rebuild is too expensive. For marts whose full build is cheap (dimensions, small aggregates, marts reading from already-built marts), incremental is pure downside.

Promoting a mart to incremental later is a half-day per mart. Premature blanket conversion isn't future-proofing — it's just bugs we don't have yet.

### Why incremental on staging (Phase B)

Two reasons:
1. Marts need a stable, indexed watermark column. Re-projecting `ts_ms` from raw events on every mart query is expensive.
2. Materializing staging once and reading from it many times is cheaper than scanning raw events repeatedly across many mart builds.

Tradeoff: one extra cycle of latency between CDC arrival and visibility in marts. Acceptable for an hourly refresh DAG.

### Why split `make setup` from initial dbt build (Phase D)

The current `make setup` conflates two very different things:
- **Setup of the platform** — idempotent, fast, safe (register connector, init schemas, import dashboards).
- **Initial data build** — heavy, one-time, environment-specific (full dbt rebuild over all CDC history).

Treating these as one means every redeploy re-runs the heavy step. It's also what made our Jenkins re-runs dangerous — the heavy step can damage existing marts (drop-then-rename swap pattern). Splitting them makes:
- Deploys safe and cheap, always.
- The heavy step an explicit decision by the operator, on the operator's schedule.

This mirrors how production data systems are deployed: code/infrastructure deploys are decoupled from data backfills.

### Why pin `threads: 1` (Phase E)

dbt-clickhouse 1.10 has a race where multiple worker threads share a ClickHouse session_id and trigger `SESSION_IS_LOCKED`. We hit this directly. The race window is small at fast model sizes and large at slow ones (which is exactly when we don't want extra failure modes). `threads: 1` removes the race; with incremental models being small per run, the wall-clock cost is negligible. Revisit once the adapter has a confirmed fix.

### Why per-query ClickHouse memory caps (Phase E)

When a single query gets near `max_server_memory_usage` (defaults to 90% of host RAM), ClickHouse self-terminates to avoid kernel OOM. That's worse than getting `MEMORY_LIMIT_EXCEEDED` on the query, because it takes down the whole server and cascades into "connection refused" for every other client. A per-query cap (e.g. 20 GiB on a 32 GiB box) means one bad query fails visibly and the server stays up.

## What does NOT change

- OLMIS deploy flow.
- CDC ingestion (raw is fine).
- Superset dashboards or dataset names.
- Heartbeat / replication slot mechanics.
- Source DB or schema.

Blast radius is the dbt layer + the `setup.sh` script + the dbt profile/Dockerfile.

## Acceptance criteria

1. `make setup` on an already-deployed stack does **no dbt work** and finishes in under a minute.
2. A fresh `make initial-dbt-build` on the Malawi dev box completes without ClickHouse self-terminating, using <80% of available RAM.
3. Two consecutive `dbt run`s after the initial build process **only the delta** (verified by inspecting dbt's per-model row counts).
4. The Airflow `platform_refresh` DAG completes hourly on dev without errors for at least 48 hours.
5. A Jenkins redeploy (KEEP=keep) succeeds end-to-end with no mart damage and no human intervention.
6. `docs/operations.md` and `docs/architecture.md` reflect the new lifecycle.

## Tracker

- [ ] Phase A — audit, fill in the per-mart table above
- [ ] Phase B — staging incremental + `_cdc_ts`
- [ ] Phase C — refactor big marts (list locked in Phase A)
- [ ] Phase D — split `make setup` / `make initial-dbt-build`
- [ ] Phase E — `threads: 1`, query memory cap, DAG hardening
- [ ] Phase F — verify on Malawi dev, update docs

## Notes for whoever picks this up

- The Malawi dev box (`lmis-dev.health.gov.mw`) is the realistic test environment. As of 2026-05-28 it has the snapshot complete (49 M raw rows) and the marts in working state. Don't burn that state without saving the volume — the snapshot is hours of wall-clock to redo.
- The current `mart_stock_status` row count (~3,651) reflects the 3-year date filter; that's the right magnitude. The cost is in the *scan* upstream, not the result.
- The dev box is `r5.xlarge` (4 vCPU / 32 GB). The host OS/Docker are pre-`clone3` era (Ubuntu 16.04, Docker 19.03, libseccomp 2.4.3), so the `compose/docker-compose.seccomp-unconfined.yml` overlay must be applied (`COMPOSE_OVERLAY=…seccomp-unconfined.yml make up`). Separate from this refactor; documented in `mw-openlmis-deployment/deployment/dev_env/reporting-stack-setup.md`.

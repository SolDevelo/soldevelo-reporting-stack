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

### Phase A — Audit (~½ day) — **DONE 2026-05-28**

Walked every model in `examples/olmis-analytics-core/dbt/models/marts/` and `examples/olmis-analytics-malawi/dbt/models/marts/`. Classified by:

| Question | Answer determines |
| --- | --- |
| What's the largest source it scans? | If <1 M rows → `table`. If multi-million → candidate for `incremental`. |
| Does it have a natural `unique_key` (PK, or composite)? | If no, incremental is harder; consider keeping as `table` or building a key. |
| Are source deletes meaningful to the dashboards? | If yes and frequent, needs explicit delete handling. |
| Is it a dimension (mirrors a source table) or an aggregate? | Dimensions stay `table`. |

Default for any mart whose largest scan is <1 M rows: stay as `table`.

**Findings — per mart:**

| Mart | Largest scan | Unique key | Deletes matter | Shape | Decision | Watermark | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `mart_facility_directory` | `stg_facilities` (~1.7 k) | `facility_id` | rarely | dimension | **table** | — | Pure facility-dimension join. Full rebuild is free. |
| `mart_requisition_summary` | `stg_requisitions` (~1.2 M) | `requisition_id` | rarely | per-row enrichment | **table** | (`_cdc_ts` available if promoted) | 1.2 M is below the memory wall today; full rebuild stays cheap. Promote later only if scan cost becomes a problem. |
| `mart_stock_status` | `stg_requisition_line_items` (~28.8 M) | `line_item_id` | rarely (requisition line edits, not deletes) | per-row enrichment | **incremental** | `_cdc_ts` from `stg_requisition_line_items` | The confirmed memory bomb. Output is small (~3.6 k after 3-yr filter) but the upstream scan is what kills ClickHouse. |
| `mart_adjustments` | `stg_stock_adjustments` (scales with line items) + `stg_stock_adjustment_reasons` (13.8 M raw, deduped to ~global N) | `adjustment_id` | rarely | per-row enrichment | **incremental** | `_cdc_ts` from `stg_stock_adjustments` | Reasons dedupe to a tiny set (one row per global `reason_id`). The cost is the adjustments scan; watermark on adjustments side. |
| `mart_reporting_status` | `stg_status_changes` (~3.5 M) joined to `stg_requisitions` (~1.2 M) plus a cross-product over expected (facility × program × period) | composite (facility_id, program_id, period_id) | no | aggregate / cross-product | **table** | — | Output is cross-product of expected reporting obligations; the upstream scans aren't crippling and the per-mart row count is the bottleneck. Adding a new requisition can change rows at the (facility, program, period) granularity, which is awkward for delta semantics. Keep as `table`; promote later only if upstream scan cost actually starts to hurt. |
| `mart_non_reporting_facilities` | same as `mart_reporting_status` (independent recompute) | composite (facility_id, program_id, period_id) | no | aggregate (filtered) | **table** | — | Same reasoning as `mart_reporting_status`. Could later refactor to derive from `mart_reporting_status` to save a duplicate scan — out of scope for this refactor. |
| `mart_logistics_summary` | `mart_stock_status` (curated, small) | derived | no | aggregate | **table** | — | Top-5 products by consumption — 49 rows. Cheap and small. |
| `mart_malawi_requisition_by_region` | `mart_requisition_summary`, `mart_facility_directory` (both curated) | composite (region, program, status) | no | aggregate | **table** | — | Reads from already-built core marts. Cheap. |
| `mart_malawi_stock_status` | `mart_stock_status` joined to seed (114 rows) | `line_item_id` | no | per-row filter | **table** | — | Reads from already-built core mart. Cheap. |

**Promotions** (table → incremental): `mart_stock_status`, `mart_adjustments`. Everything else stays as `table`.

**Audit finding that changes Phase B's design — staging is current-state, not append-only.**

Every `stg_*` model in `olmis-analytics-core/dbt/models/staging/` does **current-state reconstruction**:

```sql
row_number() over (partition by id order by ts_ms desc, _ingested_at desc) as _rn
... where _rn = 1 and op != 'd'
```

i.e. each row in staging is the latest non-deleted version of one source row. This is the right shape for marts (which need facility / requisition / line-item dimensions in their current state), but it means Phase B's "incremental + append" doesn't apply verbatim. A pure append would emit a second row per id every time the source updates; the `row_number()` window only sees rows in the current batch, so the materialized output would no longer be one-row-per-id.

Refined Phase B design is documented under "Phase B" below.

### Phase B — Staging watermark (~½–1 day)

Convert `stg_*` from `view` to `materialized='incremental'` with `incremental_strategy='delete+insert'`. Each `stg_X` continues to expose exactly one row per source id (current-state semantics, unchanged), and additionally carries:
- `_cdc_ts_ms` — the `ts_ms` of the latest event for this id (the row that won the `row_number()` race). Used as the watermark on subsequent runs.
- `_cdc_ts` — `toDateTime64(_cdc_ts_ms / 1000, 3)`. Exposed for downstream marts to filter on.
- `_cdc_op` — Debezium `op` of the winning row (`r`/`c`/`u`).

Pattern (illustrative — adapt the partition keys for composite-PK tables):

```sql
{{ config(
    materialized='incremental',
    incremental_strategy='delete+insert',
    unique_key='id',
    engine='MergeTree()',
    order_by='id'
) }}

with touched_ids as (
  -- ids with at least one new event since the last run
  select distinct coalesce(
    nullIf(JSONExtractString(after,  'id'), ''),
    nullIf(JSONExtractString(before, 'id'), '')
  ) as id
  from raw.events_<topic>
  where coalesce(
    nullIf(JSONExtractString(after,  'id'), ''),
    nullIf(JSONExtractString(before, 'id'), '')
  ) != ''
  {% if is_incremental() %}
    and ts_ms > (select coalesce(max(_cdc_ts_ms), 0) from {{ this }})
  {% endif %}
),
ranked as (
  -- re-rank across full raw history for the touched ids only
  select e.*,
         row_number() over (
           partition by coalesce(
             nullIf(JSONExtractString(e.after,  'id'), ''),
             nullIf(JSONExtractString(e.before, 'id'), '')
           )
           order by e.ts_ms desc, e._ingested_at desc
         ) as _rn
  from raw.events_<topic> e
  inner join touched_ids t
    on coalesce(
         nullIf(JSONExtractString(e.after,  'id'), ''),
         nullIf(JSONExtractString(e.before, 'id'), '')
       ) = t.id
)
select
  ... existing column projections ...,
  ts_ms                                  as _cdc_ts_ms,
  toDateTime64(ts_ms / 1000, 3)          as _cdc_ts,
  op                                     as _cdc_op
from ranked
where _rn = 1
  and op != 'd'
```

Effect: a `dbt run` scans raw events twice — once to find `touched_ids` (cheap; `ts_ms` is in the raw MergeTree `ORDER BY`, so `ts_ms > watermark` is a range scan), then once to rank the full history of those ids only. On a quiet hour (few new events) this is near-zero work; on a backfill it converges to the full-history rank.

`delete+insert` with `unique_key='id'` then upserts the re-ranked rows: rows that already existed in staging get replaced with their new current state.

**Source-delete limitation (documented, not fixed in this phase).** If a row is hard-deleted in source, its latest CDC event has `op='d'` and is filtered out of the SELECT — so the stale row remains in staging. The same is true for marts. Reconcile via `dbt run --full-refresh` when source deletes are suspected. In OpenLMIS this is extremely rare for the tables involved (you don't hard-delete requisitions, line items, status changes, or stock adjustments in practice).

**Composite-PK tables.** `stg_requisition_group_members` (PK: `requisition_group_id, facility_id`) and `stg_supported_programs` (PK: `facility_id, program_id`) need `unique_key` set to the composite tuple and the partition/join keys adjusted accordingly. The `touched_ids` CTE projects the composite as a single concatenated string or tuple.

**`stg_stock_adjustment_reasons`.** Original does a two-stage dedupe (rank per source `id`, then `argMax` per global `reason_id`). The incremental version collapses both stages by partitioning the window over the **global** `reasonid` directly: `unique_key='reason_id'`, `touched_reason_ids` finds reasonids with new events, and we re-rank by ts_ms within each reasonid across the full raw history. Output is one row per global `reason_id` — same as before. Safe to do because every `(requisition, reason)` copy of a given `reasonid` carries identical `name` / `reasontype` / `reasoncategory` (the design invariant of this table); the legacy `argMax(., id)` was just a deterministic tiebreaker. Simpler than splitting into `__raw` + view and avoids materializing a ~60 M-row intermediate.

**Selective materialization** — not all staging needs incremental. The audit identified 5 fact-shaped tables that warrant it (`stg_requisitions`, `stg_requisition_line_items`, `stg_status_changes`, `stg_stock_adjustments`, `stg_stock_adjustment_reasons`). The 10 small dimensions (`stg_facilities`, `stg_facility_types`, `stg_geographic_zones`, `stg_orderables`, `stg_processing_periods`, `stg_processing_schedules`, `stg_programs`, `stg_requisition_group_members`, `stg_requisition_group_program_schedules`, `stg_supported_programs`) stay as views — their raw events tables are small, re-running the window function on each read is cheap, and they don't drive any mart's incrementality (incremental marts watermark on the fact-side `_cdc_ts`, not the dimension-side).

Staging tables lag raw by at most one cycle (acceptable; dashboards aren't real-time).

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

- [x] Phase A — audit, fill in the per-mart table above (2026-05-28)
- [x] Phase B — staging incremental + `_cdc_ts` (2026-05-28)
- [x] Phase C — refactor `mart_stock_status` + `mart_adjustments` (2026-05-28)
- [x] Phase D — split `make setup` / `make initial-dbt-build` (2026-05-28)
- [x] Phase E — `threads: 1`, query memory cap, DAG hardening (2026-05-28)
- [ ] Phase F — verify on Malawi dev, update docs/architecture.md

## Notes for whoever picks this up

- The Malawi dev box (`lmis-dev.health.gov.mw`) is the realistic test environment. As of 2026-05-28 it has the snapshot complete (49 M raw rows) and the marts in working state. Don't burn that state without saving the volume — the snapshot is hours of wall-clock to redo.
- The current `mart_stock_status` row count (~3,651) reflects the 3-year date filter; that's the right magnitude. The cost is in the *scan* upstream, not the result.
- The dev box is `r5.xlarge` (4 vCPU / 32 GB). The host OS/Docker are pre-`clone3` era (Ubuntu 16.04, Docker 19.03, libseccomp 2.4.3), so the `compose/docker-compose.seccomp-unconfined.yml` overlay must be applied (`COMPOSE_OVERLAY=…seccomp-unconfined.yml make up`). Separate from this refactor; documented in `mw-openlmis-deployment/deployment/dev_env/reporting-stack-setup.md`.

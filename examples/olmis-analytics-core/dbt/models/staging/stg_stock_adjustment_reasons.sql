{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for requisition.stock_adjustment_reasons.
-- The raw table has one row per (requisition, allowed reason) — i.e. each
-- requisition has its own copy of the global reasons. Because all rows
-- with the same `reasonid` (the global FK) carry identical `name` and
-- `reasontype` values, we deduplicate by reasonid for downstream joins.
-- The mart then joins stg_stock_adjustments.reason_id to this view's
-- reason_id (1:1 instead of 1:n).

with ranked as (
  select
    *,
    row_number() over (
      partition by coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      )
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_requisition_stock_adjustment_reasons
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
),

current_state as (
  select
    toUUID(JSONExtractString(after, 'id'))                  as id,
    toUUIDOrNull(JSONExtractString(after, 'reasonid'))      as reason_id,
    toUUIDOrNull(JSONExtractString(after, 'requisitionid')) as requisition_id,
    JSONExtractString(after, 'name')                        as name,
    JSONExtractString(after, 'reasontype')                  as reason_type,
    JSONExtractString(after, 'reasoncategory')              as reason_category,
    JSONExtractBool(after, 'hidden')                        as hidden
  from ranked
  where _rn = 1
    and op != 'd'
)

-- Deduplicate to one row per global reason_id. argMax picks the name
-- from the row with the largest id (deterministic, arbitrary tiebreaker).
select
  reason_id                         as reason_id,
  argMax(name, id)                  as name,
  argMax(reason_type, id)           as reason_type,
  argMax(reason_category, id)       as reason_category
from current_state
where reason_id is not null
group by reason_id

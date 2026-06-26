{{
  config(
    materialized='incremental',
    incremental_strategy='delete_insert',
    unique_key='reason_id',
    engine='MergeTree()',
    order_by='reason_id',
    settings={'allow_nullable_key': 1}
  )
}}

-- Current-state reconstruction for requisition.stock_adjustment_reasons,
-- deduplicated to one row per global reason_id.
--
-- The raw table has one row per (requisition, allowed reason) — i.e. each
-- requisition has its own copy of the global reasons. All rows with the
-- same `reasonid` (the global FK) carry identical `name` / `reasontype` /
-- `reasoncategory` values, so we collapse to one row per reason_id for
-- downstream joins (mart_adjustments joins on reason_id, not on the
-- per-requisition source id).
--
-- Incremental design: we partition the window by `reasonid` (the global
-- key, also our unique_key) and rank by ts_ms. On each run, touched
-- reason_ids = those with at least one new event since the watermark; we
-- then re-rank across the full raw history for those reason_ids only.
-- Because we partition by the global key, the latest event for any
-- (requisition, reason) pair with that reasonid wins — equivalent to the
-- legacy argMax(., id) since all copies carry identical attribute values.

with touched_reason_ids as (
  select distinct coalesce(
    nullIf(JSONExtractString(after,  'reasonid'), ''),
    nullIf(JSONExtractString(before, 'reasonid'), '')
  ) as reason_id_str
  from raw.events_openlmis_requisition_stock_adjustment_reasons
  where coalesce(
        nullIf(JSONExtractString(after,  'reasonid'), ''),
        nullIf(JSONExtractString(before, 'reasonid'), '')
      ) != ''
  {% if is_incremental() %}
    and ts_ms > (select coalesce(max(_cdc_ts_ms), 0) from {{ this }})
  {% endif %}
),

ranked as (
  select
    e.*,
    row_number() over (
      partition by coalesce(
        nullIf(JSONExtractString(e.after,  'reasonid'), ''),
        nullIf(JSONExtractString(e.before, 'reasonid'), '')
      )
      order by e.ts_ms desc, e._ingested_at desc
    ) as _rn
  from raw.events_openlmis_requisition_stock_adjustment_reasons e
  inner join touched_reason_ids t
    on coalesce(
         nullIf(JSONExtractString(e.after,  'reasonid'), ''),
         nullIf(JSONExtractString(e.before, 'reasonid'), '')
       ) = t.reason_id_str
)

select
  toUUIDOrNull(JSONExtractString(after, 'reasonid'))      as reason_id,
  JSONExtractString(after, 'name')                        as name,
  JSONExtractString(after, 'reasontype')                  as reason_type,
  JSONExtractString(after, 'reasoncategory')              as reason_category,

  -- CDC watermark columns
  ts_ms                                                   as _cdc_ts_ms,
  toDateTime64(ts_ms / 1000, 3)                           as _cdc_ts,
  op                                                      as _cdc_op
from ranked
where _rn = 1
  and op != 'd'
  and coalesce(
        nullIf(JSONExtractString(after,  'reasonid'), ''),
        nullIf(JSONExtractString(before, 'reasonid'), '')
      ) != ''

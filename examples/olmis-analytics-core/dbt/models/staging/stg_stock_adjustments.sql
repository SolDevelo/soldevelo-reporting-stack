{{
  config(
    materialized='incremental',
    incremental_strategy='delete_insert',
    unique_key='id',
    engine='MergeTree()',
    order_by='id',
    settings={'allow_nullable_key': 1}
  )
}}

-- Current-state reconstruction for requisition.stock_adjustments.
-- One row per adjustment line; quantity is positive (sign comes from the
-- reason's reasontype: CREDIT = +, DEBIT = -).
-- Incremental: only re-ranks ids whose raw events arrived after the
-- materialized watermark. See stg_requisitions for the full pattern.

with touched_ids as (
  select distinct coalesce(
    nullIf(JSONExtractString(after,  'id'), ''),
    nullIf(JSONExtractString(before, 'id'), '')
  ) as id_str
  from raw.events_openlmis_requisition_stock_adjustments
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
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
        nullIf(JSONExtractString(e.after,  'id'), ''),
        nullIf(JSONExtractString(e.before, 'id'), '')
      )
      order by e.ts_ms desc, e._ingested_at desc
    ) as _rn
  from raw.events_openlmis_requisition_stock_adjustments e
  inner join touched_ids t
    on coalesce(
         nullIf(JSONExtractString(e.after,  'id'), ''),
         nullIf(JSONExtractString(e.before, 'id'), '')
       ) = t.id_str
)

select
  toUUID(JSONExtractString(after, 'id'))                            as id,
  toUUIDOrNull(JSONExtractString(after, 'requisitionlineitemid'))   as requisition_line_item_id,
  toUUIDOrNull(JSONExtractString(after, 'reasonid'))                as reason_id,
  JSONExtractInt(after, 'quantity')                                 as quantity,

  -- CDC watermark columns
  ts_ms                                                             as _cdc_ts_ms,
  toDateTime64(ts_ms / 1000, 3)                                     as _cdc_ts,
  op                                                                as _cdc_op
from ranked
where _rn = 1
  and op != 'd'

{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for requisition.stock_adjustments.
-- One row per adjustment line; quantity is positive (sign comes from the
-- reason's reasontype: CREDIT = +, DEBIT = -).

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
  from raw.events_openlmis_requisition_stock_adjustments
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                            as id,
  toUUIDOrNull(JSONExtractString(after, 'requisitionlineitemid'))   as requisition_line_item_id,
  toUUIDOrNull(JSONExtractString(after, 'reasonid'))                as reason_id,
  JSONExtractInt(after, 'quantity')                                 as quantity
from ranked
where _rn = 1
  and op != 'd'

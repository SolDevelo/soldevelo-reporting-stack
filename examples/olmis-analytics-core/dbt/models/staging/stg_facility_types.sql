{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.facility_types.

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
  from raw.events_openlmis_referencedata_facility_types
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))    as id,
  JSONExtractString(after, 'code')          as code,
  JSONExtractString(after, 'name')          as name,
  JSONExtractBool(after, 'active')          as active,
  JSONExtractInt(after, 'displayorder')     as display_order
from ranked
where _rn = 1
  and op != 'd'

{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.processing_schedules.

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_processing_schedules
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
)

select
  toUUID(JSONExtractString(after, 'id'))    as id,
  JSONExtractString(after, 'code')          as code,
  JSONExtractString(after, 'name')          as name,
  JSONExtractString(after, 'description')   as description
from ranked
where _rn = 1

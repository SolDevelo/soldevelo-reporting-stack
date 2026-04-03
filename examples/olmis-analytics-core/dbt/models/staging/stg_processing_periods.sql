{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.processing_periods.

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_processing_periods
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                       as id,
  JSONExtractString(after, 'name')                             as name,
  toDate(toDate('1970-01-01') + JSONExtractInt(after, 'startdate'))     as start_date,
  toDate(toDate('1970-01-01') + JSONExtractInt(after, 'enddate'))      as end_date,
  toUUIDOrNull(JSONExtractString(after, 'processingscheduleid'))       as processing_schedule_id,
  JSONExtractString(after, 'description')                      as description
from ranked
where _rn = 1

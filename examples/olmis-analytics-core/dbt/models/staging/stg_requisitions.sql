{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for requisition.requisitions.

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_requisition_requisitions
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
)

select
  toUUID(JSONExtractString(after, 'id'))                  as id,
  JSONExtractString(after, 'status')                      as status,
  JSONExtractBool(after, 'emergency')                     as emergency,
  toUUIDOrNull(JSONExtractString(after, 'facilityid'))    as facility_id,
  toUUIDOrNull(JSONExtractString(after, 'programid'))     as program_id,
  toUUIDOrNull(JSONExtractString(after, 'processingperiodid'))  as processing_period_id,
  toUUIDOrNull(JSONExtractString(after, 'supervisorynodeid'))   as supervisory_node_id,
  JSONExtractInt(after, 'numberofmonthsinperiod')         as number_of_months_in_period,
  parseDateTimeBestEffortOrNull(JSONExtractString(after, 'createddate'))   as created_date,
  parseDateTimeBestEffortOrNull(JSONExtractString(after, 'modifieddate'))  as modified_date
from ranked
where _rn = 1

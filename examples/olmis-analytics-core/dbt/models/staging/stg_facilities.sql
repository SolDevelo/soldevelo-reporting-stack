{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.facilities.
-- Selects the latest CDC event per facility ID; rows whose latest event
-- is a delete are dropped after ranking. The partition key uses
-- coalesce(after.id, before.id) so delete events (which have after=NULL)
-- join the same partition as their corresponding insert/update.

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
  from raw.events_openlmis_referencedata_facilities
  where coalesce(
        nullIf(JSONExtractString(after,  'id'), ''),
        nullIf(JSONExtractString(before, 'id'), '')
      ) != ''
)

select
  toUUID(JSONExtractString(after, 'id'))               as id,
  JSONExtractString(after, 'code')                      as code,
  JSONExtractString(after, 'name')                      as name,
  JSONExtractBool(after, 'active')                      as active,
  JSONExtractBool(after, 'enabled')                     as enabled,
  JSONExtractBool(after, 'openlmisaccessible')          as openlmis_accessible,
  toUUIDOrNull(JSONExtractString(after, 'geographiczoneid'))  as geographic_zone_id,
  toUUIDOrNull(JSONExtractString(after, 'typeid'))            as type_id,
  toUUIDOrNull(JSONExtractString(after, 'operatedbyid'))      as operated_by_id
from ranked
where _rn = 1
  and op != 'd'

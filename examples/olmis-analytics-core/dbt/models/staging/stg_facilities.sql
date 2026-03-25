{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.facilities.
-- Selects the latest CDC event per facility ID, excluding deletes.

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_facilities
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
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

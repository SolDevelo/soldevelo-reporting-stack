{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.geographic_zones.

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_geographic_zones
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
)

select
  toUUID(JSONExtractString(after, 'id'))            as id,
  JSONExtractString(after, 'code')                  as code,
  JSONExtractString(after, 'name')                  as name,
  toUUIDOrNull(JSONExtractString(after, 'levelid'))   as level_id,
  toUUIDOrNull(JSONExtractString(after, 'parentid'))  as parent_id,
  JSONExtractInt(after, 'catchmentpopulation')      as catchment_population,
  JSONExtractFloat(after, 'latitude')               as latitude,
  JSONExtractFloat(after, 'longitude')              as longitude
from ranked
where _rn = 1

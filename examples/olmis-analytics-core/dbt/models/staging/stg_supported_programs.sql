{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.supported_programs.
-- Composite PK: (facilityid, programid) — no single id column.

with ranked as (
  select
    *,
    row_number() over (
      partition by
        JSONExtractString(after, 'facilityid'),
        JSONExtractString(after, 'programid')
      order by ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_supported_programs
  where op != 'd'
    and JSONExtractString(after, 'facilityid') != ''
    and JSONExtractString(after, 'programid') != ''
)

select
  toUUIDOrNull(JSONExtractString(after, 'facilityid'))  as facility_id,
  toUUIDOrNull(JSONExtractString(after, 'programid'))   as program_id,
  JSONExtractBool(after, 'active')                      as active,
  JSONExtractBool(after, 'locallyfulfilled')             as locally_fulfilled
from ranked
where _rn = 1

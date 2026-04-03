{{
  config(
    materialized='view'
  )
}}

-- Current-state reconstruction for referencedata.orderables.
-- Orderables are versioned (composite PK: id + versionnumber).
-- This picks the latest version per orderable ID.

with ranked as (
  select
    *,
    row_number() over (
      partition by JSONExtractString(after, 'id')
      order by JSONExtractInt(after, 'versionnumber') desc, ts_ms desc, _ingested_at desc
    ) as _rn
  from raw.events_openlmis_referencedata_orderables
  where op != 'd'
    and JSONExtractString(after, 'id') != ''
)

select
  toUUID(JSONExtractString(after, 'id'))          as id,
  JSONExtractString(after, 'code')                as code,
  JSONExtractString(after, 'fullproductname')     as full_product_name,
  JSONExtractString(after, 'description')         as description,
  JSONExtractInt(after, 'netcontent')             as net_content,
  JSONExtractInt(after, 'packroundingthreshold')  as pack_rounding_threshold,
  JSONExtractBool(after, 'roundtozero')           as round_to_zero,
  JSONExtractInt(after, 'versionnumber')          as version_number
from ranked
where _rn = 1

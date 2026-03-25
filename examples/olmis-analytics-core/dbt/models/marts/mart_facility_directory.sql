{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(geographic_zone_name, facility_name)'
  )
}}

-- Facility directory: enriched facility list with geographic zone names.
-- This is a curated mart — the stable contract for BI dashboards.

select
  f.id              as facility_id,
  f.code            as facility_code,
  f.name            as facility_name,
  f.active          as facility_active,
  f.enabled         as facility_enabled,
  gz.id             as geographic_zone_id,
  gz.code           as geographic_zone_code,
  gz.name           as geographic_zone_name,
  gz.latitude       as geographic_zone_latitude,
  gz.longitude      as geographic_zone_longitude,
  parent_gz.id      as parent_zone_id,
  parent_gz.name    as parent_zone_name
from {{ ref('stg_facilities') }} f
left join {{ ref('stg_geographic_zones') }} gz
  on f.geographic_zone_id = gz.id
left join {{ ref('stg_geographic_zones') }} parent_gz
  on gz.parent_id = parent_gz.id

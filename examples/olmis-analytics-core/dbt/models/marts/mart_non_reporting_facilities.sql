{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(program_name, period_end_date, facility_name)'
  )
}}

-- Non-reporting facilities: active facilities that did not submit a
-- requisition for a given program and period.
--
-- Matches the legacy reporting_rate_and_timeliness materialized view logic:
--   - Uses supported_programs to determine which facilities should report
--   - Uses requisition_group_members + requisition_group_program_schedules
--     to determine the correct processing schedule per facility-program
--   - Uses status_changes to check if a requisition was SUBMITTED
--   - Only includes active, enabled facilities with active program support
-- Rolling 3-year window on requisition created_date.

with facility_program_schedules as (
  -- Authoritative mapping: facility → program → processing schedule.
  select distinct
    sp.facility_id                   as facility_id,
    sp.program_id                    as program_id,
    rgps.processing_schedule_id      as processing_schedule_id
  from {{ ref('stg_supported_programs') }} sp
  inner join {{ ref('stg_requisition_group_members') }} rgm
    on rgm.facility_id = sp.facility_id
  inner join {{ ref('stg_requisition_group_program_schedules') }} rgps
    on rgps.requisition_group_id = rgm.requisition_group_id
    and rgps.program_id = sp.program_id
  where sp.active = true
),

-- Expected: each facility-program matched to periods from its assigned schedule
expected as (
  select
    fps.facility_id                  as facility_id,
    fps.program_id                   as program_id,
    pp.id                            as period_id,
    pp.name                          as period_name,
    pp.start_date                    as period_start_date,
    pp.end_date                      as period_end_date
  from facility_program_schedules fps
  inner join {{ ref('stg_processing_periods') }} pp
    on pp.processing_schedule_id = fps.processing_schedule_id
  where pp.end_date >= now() - interval 3 year
),

-- Actual submissions: requisitions that have been at least SUBMITTED
submitted as (
  select distinct
    r.facility_id                    as facility_id,
    r.program_id                     as program_id,
    r.processing_period_id           as processing_period_id
  from {{ ref('stg_requisitions') }} r
  inner join {{ ref('stg_status_changes') }} sc
    on sc.requisition_id = r.id
    and sc.status = 'SUBMITTED'
  where r.created_date >= now() - interval 3 year
    and r.emergency = false
)

select
  e.facility_id,
  f.code            as facility_code,
  f.name            as facility_name,
  f.active          as facility_active,
  ft.name           as facility_type_name,
  gz.name           as zone_name,
  parent_gz.name    as parent_zone_name,
  p.name            as program_name,
  p.code            as program_code,
  e.period_name,
  e.period_start_date,
  e.period_end_date,
  'Did not report'  as reporting_status
from expected e
left join submitted s
  on e.facility_id = s.facility_id
  and e.program_id = s.program_id
  and e.period_id  = s.processing_period_id
inner join {{ ref('stg_facilities') }} f
  on e.facility_id = f.id
left join {{ ref('stg_facility_types') }} ft
  on f.type_id = ft.id
left join {{ ref('stg_geographic_zones') }} gz
  on f.geographic_zone_id = gz.id
left join {{ ref('stg_geographic_zones') }} parent_gz
  on gz.parent_id = parent_gz.id
inner join {{ ref('stg_programs') }} p
  on e.program_id = p.id
where f.active = true
  and f.enabled = true
  and s.facility_id is null

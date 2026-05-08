{{
  config(
    materialized='table',
    engine='MergeTree()',
    order_by='(program_name, period_end_date, facility_name)',
    settings={'allow_nullable_key': 1}
  )
}}

-- Reporting status per facility × program × period: one row for every
-- expected reporting obligation, marked as 'Reported' or 'Did not report'.
-- Superset of mart_non_reporting_facilities (which is filtered to the
-- 'Did not report' subset).
--
-- Matches the legacy reporting_rate_and_timeliness materialized view:
--   - supported_programs determines who must report
--   - requisition_group_members + requisition_group_program_schedules
--     determine the schedule each (facility, program) follows
--   - status_changes (status='SUBMITTED') determines if a report happened
--   - reporting_status: 'Reported' iff a SUBMITTED requisition exists for
--     the (facility, program, period) combination, else 'Did not report'
--   - submitted_date / submitted_week_of_month: from the SUBMITTED status
--     change, used by the "Reporting Timeliness By Week" chart to bucket
--     submissions into weeks 1–5 of the month
--   - Excludes emergency requisitions (matches legacy MV)
-- Rolling 3-year window on processing_period.end_date.

with facility_program_schedules as (
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

expected as (
  select
    fps.facility_id,
    fps.program_id,
    pp.id            as period_id,
    pp.name          as period_name,
    pp.start_date    as period_start_date,
    pp.end_date      as period_end_date
  from facility_program_schedules fps
  inner join {{ ref('stg_processing_periods') }} pp
    on pp.processing_schedule_id = fps.processing_schedule_id
  where pp.end_date >= now() - interval 3 year
),

submitted as (
  -- The earliest SUBMITTED status change per requisition is the "submission"
  -- timestamp. Only one row per (facility, program, period).
  select
    r.facility_id                    as facility_id,
    r.program_id                     as program_id,
    r.processing_period_id           as processing_period_id,
    min(sc.created_date)             as submitted_date
  from {{ ref('stg_requisitions') }} r
  inner join {{ ref('stg_status_changes') }} sc
    on sc.requisition_id = r.id
    and sc.status = 'SUBMITTED'
  where r.created_date >= now() - interval 3 year
    and r.emergency = false
  group by r.facility_id, r.program_id, r.processing_period_id
)

select
  e.facility_id     as facility_id,
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

  -- reporting outcome
  case when s.facility_id is null
       then 'Did not report'
       else 'Reported'
  end                                       as reporting_status,
  s.submitted_date,

  -- Week-of-month bucket (1..5) for the submission date, used by the
  -- legacy "Reporting Timeliness By Week" chart. Computed from day-of-month
  -- floor-div 7 + 1 (matches the legacy SQL spirit; tweaked for ClickHouse
  -- date arithmetic).
  case
    when s.submitted_date is null then null
    else cast(floor((toDayOfMonth(s.submitted_date) - 1) / 7) + 1 as UInt8)
  end                                       as submitted_week_of_month

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

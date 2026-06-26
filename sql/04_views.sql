-- =============================================================================
-- Power Utility Asset Management — Views
-- File: 04_views.sql
--
-- 1. vw_overdue_assets    — assets with a preventive-maintenance schedule whose
--                           next_due_date has passed (or that have never been
--                           inspected), ranked by how overdue + criticality.
--
-- 2. vw_technician_workload — per-technician active/completed load, hours,
--                             utilization vs. capacity, and availability.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- VIEW 1: Overdue assets.
--   An asset row appears when an active maintenance schedule is past due.
--   days_overdue is positive when overdue. Critical assets float to the top.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_overdue_assets AS
SELECT
    a.asset_id,
    a.asset_tag,
    a.name                       AS asset_name,
    a.asset_type,
    a.location,
    a.status                     AS asset_status,
    a.criticality,
    a.last_inspected_date,
    ms.schedule_id,
    ms.task_name,
    ms.next_due_date,
    (CURRENT_DATE - ms.next_due_date)        AS days_overdue,
    ms.default_priority,
    -- A simple urgency score: more overdue + more critical = higher.
    ((CURRENT_DATE - ms.next_due_date) * a.criticality) AS urgency_score
FROM maintenance_schedules ms
JOIN assets a ON a.asset_id = ms.asset_id
WHERE ms.is_active = TRUE
  AND ms.next_due_date < CURRENT_DATE
  AND a.status <> 'decommissioned'
ORDER BY urgency_score DESC, ms.next_due_date ASC;

COMMENT ON VIEW vw_overdue_assets IS
    'Assets with past-due active maintenance schedules, ranked by urgency.';

-- -----------------------------------------------------------------------------
-- VIEW 2: Technician workload.
--   One row per technician with active/completed counts, hours logged, and
--   utilization as active orders / capacity.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_technician_workload AS
SELECT
    t.technician_id,
    t.employee_code,
    (t.first_name || ' ' || t.last_name)      AS technician_name,
    t.specialization,
    t.certification_level,
    t.is_available,
    t.max_active_orders,
    COUNT(wo.work_order_id) FILTER (
        WHERE wo.status IN ('assigned','in_progress','on_hold')
    )                                          AS active_orders,
    COUNT(wo.work_order_id) FILTER (
        WHERE wo.status = 'completed'
    )                                          AS completed_orders,
    COUNT(wo.work_order_id) FILTER (
        WHERE wo.status IN ('assigned','in_progress','on_hold')
          AND wo.priority IN ('high','critical')
    )                                          AS active_high_priority,
    COALESCE(SUM(wo.actual_hours) FILTER (
        WHERE wo.status = 'completed'
    ), 0)                                      AS total_hours_logged,
    ROUND(
        COUNT(wo.work_order_id) FILTER (
            WHERE wo.status IN ('assigned','in_progress','on_hold')
        )::numeric / NULLIF(t.max_active_orders, 0) * 100, 0
    )                                          AS utilization_pct
FROM technicians t
LEFT JOIN work_orders wo ON wo.technician_id = t.technician_id
GROUP BY t.technician_id, t.employee_code, t.first_name, t.last_name,
         t.specialization, t.certification_level, t.is_available,
         t.max_active_orders
ORDER BY active_orders DESC, technician_name;

COMMENT ON VIEW vw_technician_workload IS
    'Per-technician active/completed workload, hours, and utilization.';

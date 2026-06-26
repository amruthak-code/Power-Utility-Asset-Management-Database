-- =============================================================================
-- Power Utility Asset Management — Stored Procedures / Functions
-- File: 03_procedures.sql
--
-- 1. sp_create_work_order(...)   PROCEDURE
--      Creates a work order with validation, auto-generated work_order_number,
--      optional technician assignment (respecting capacity), and returns the
--      new id via an INOUT parameter. The audit + availability triggers fire
--      automatically.
--
-- 2. fn_generate_maintenance_report(start, end)   FUNCTION (returns table)
--      Per-asset maintenance summary over a date window: completed orders,
--      total cost, hours, average resolution days, and outstanding open work.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- PROCEDURE 1: Create a work order.
--   Call example:
--     CALL sp_create_work_order(
--       p_asset_tag      => 'TX-0001',
--       p_title          => 'Annual oil sample',
--       p_description    => 'Collect DGA oil sample',
--       p_priority       => 'high',
--       p_scheduled_date => CURRENT_DATE + 7,
--       p_estimated_hours=> 4,
--       p_employee_code  => 'TECH-002',
--       p_new_work_order_id => NULL  -- INOUT, receives the new id
--     );
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE sp_create_work_order(
    p_asset_tag         VARCHAR,
    p_title             VARCHAR,
    p_description       TEXT                      DEFAULT NULL,
    p_priority          work_order_priority_enum  DEFAULT 'medium',
    p_scheduled_date    DATE                      DEFAULT NULL,
    p_estimated_hours   NUMERIC                   DEFAULT NULL,
    p_employee_code     VARCHAR                   DEFAULT NULL,
    INOUT p_new_work_order_id INTEGER             DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_asset_id      INTEGER;
    v_technician_id INTEGER := NULL;
    v_active_count  INTEGER;
    v_cap           SMALLINT;
    v_status        work_order_status_enum := 'open';
    v_wo_number     VARCHAR(30);
BEGIN
    -- Resolve and validate the asset.
    SELECT asset_id INTO v_asset_id
      FROM assets WHERE asset_tag = p_asset_tag;
    IF v_asset_id IS NULL THEN
        RAISE EXCEPTION 'Asset with tag "%" does not exist.', p_asset_tag;
    END IF;

    -- Resolve and capacity-check the technician, if one was supplied.
    IF p_employee_code IS NOT NULL THEN
        SELECT technician_id, max_active_orders
          INTO v_technician_id, v_cap
          FROM technicians WHERE employee_code = p_employee_code;

        IF v_technician_id IS NULL THEN
            RAISE EXCEPTION 'Technician with code "%" does not exist.',
                p_employee_code;
        END IF;

        SELECT COUNT(*) INTO v_active_count
          FROM work_orders
         WHERE technician_id = v_technician_id
           AND status IN ('assigned', 'in_progress', 'on_hold');

        IF v_active_count >= v_cap THEN
            RAISE EXCEPTION
                'Technician "%" is at capacity (% / % active orders).',
                p_employee_code, v_active_count, v_cap;
        END IF;

        v_status := 'assigned';  -- assigning at creation moves it past 'open'
    END IF;

    -- Generate a readable, unique work-order number: WO-YYYY-NNNNNN
    v_wo_number := 'WO-' || to_char(CURRENT_DATE, 'YYYY') || '-' ||
                   lpad(nextval('work_orders_work_order_id_seq')::text, 6, '0');

    INSERT INTO work_orders (
        work_order_number, asset_id, technician_id, title, description,
        status, priority, scheduled_date, estimated_hours)
    VALUES (
        v_wo_number, v_asset_id, v_technician_id, p_title, p_description,
        v_status, p_priority, p_scheduled_date, p_estimated_hours)
    RETURNING work_order_id INTO p_new_work_order_id;

    RAISE NOTICE 'Created work order % (id=%) for asset %.',
        v_wo_number, p_new_work_order_id, p_asset_tag;
END;
$$;

-- -----------------------------------------------------------------------------
-- FUNCTION 2: Generate a maintenance report for a date window.
--   Returns one row per asset that had any work-order activity (completed or
--   still open) within / up to the window.
--   Usage:
--     SELECT * FROM fn_generate_maintenance_report('2025-01-01', '2025-12-31');
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_generate_maintenance_report(
    p_start_date DATE,
    p_end_date   DATE
)
RETURNS TABLE (
    asset_id            INTEGER,
    asset_tag           VARCHAR,
    asset_name          VARCHAR,
    asset_type          asset_type_enum,
    location            VARCHAR,
    completed_orders    BIGINT,
    open_orders         BIGINT,
    total_cost          NUMERIC,
    total_actual_hours  NUMERIC,
    avg_resolution_days NUMERIC,
    last_completed_date DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_start_date > p_end_date THEN
        RAISE EXCEPTION 'start_date (%) must not be after end_date (%).',
            p_start_date, p_end_date;
    END IF;

    RETURN QUERY
    SELECT
        a.asset_id,
        a.asset_tag,
        a.name,
        a.asset_type,
        a.location,
        COUNT(*) FILTER (
            WHERE wo.status = 'completed'
              AND wo.completed_date BETWEEN p_start_date AND p_end_date
        )                                                   AS completed_orders,
        COUNT(*) FILTER (
            WHERE wo.status IN ('open','assigned','in_progress','on_hold')
        )                                                   AS open_orders,
        COALESCE(SUM(wo.cost) FILTER (
            WHERE wo.status = 'completed'
              AND wo.completed_date BETWEEN p_start_date AND p_end_date
        ), 0)                                               AS total_cost,
        COALESCE(SUM(wo.actual_hours) FILTER (
            WHERE wo.status = 'completed'
              AND wo.completed_date BETWEEN p_start_date AND p_end_date
        ), 0)                                               AS total_actual_hours,
        ROUND(AVG(
            CASE WHEN wo.status = 'completed'
                  AND wo.completed_date BETWEEN p_start_date AND p_end_date
                 THEN (wo.completed_date - wo.scheduled_date)
            END
        )::numeric, 1)                                      AS avg_resolution_days,
        MAX(wo.completed_date) FILTER (
            WHERE wo.status = 'completed'
        )                                                   AS last_completed_date
    FROM assets a
    JOIN work_orders wo ON wo.asset_id = a.asset_id
    WHERE wo.created_at::date <= p_end_date
    GROUP BY a.asset_id, a.asset_tag, a.name, a.asset_type, a.location
    HAVING COUNT(*) FILTER (
                WHERE wo.status = 'completed'
                  AND wo.completed_date BETWEEN p_start_date AND p_end_date
           ) > 0
        OR COUNT(*) FILTER (
                WHERE wo.status IN ('open','assigned','in_progress','on_hold')
           ) > 0
    ORDER BY total_cost DESC, a.asset_tag;
END;
$$;

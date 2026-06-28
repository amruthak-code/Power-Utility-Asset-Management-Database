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
-- --- Schedule-fit helpers --------------------------------------------------
-- An order occupies a time window [scheduled_date .. due_date]. A technician
-- "fits" a new order only if the number of their *active* orders whose window
-- overlaps the new window is below their max_active_orders cap. This keeps a
-- technician from being double-booked across overlapping deadlines, while the
-- is_available boolean (maintained by trg_technician_availability) still
-- reflects their overall load.

-- Count a technician's active orders that overlap a [start, due] window.
-- Two windows overlap when  start_a <= due_b  AND  start_b <= due_a.
CREATE OR REPLACE FUNCTION fn_technician_overlap_count(
    p_technician_id INTEGER,
    p_scheduled     DATE,
    p_due           DATE
)
RETURNS INTEGER AS $$
    SELECT COUNT(*)::int
      FROM work_orders w
     WHERE w.technician_id = p_technician_id
       AND w.status IN ('assigned', 'in_progress', 'on_hold')
       AND COALESCE(w.scheduled_date, w.created_at::date) <= p_due
       AND w.due_date >= p_scheduled;
$$ LANGUAGE sql STABLE;

-- TRUE when the technician exists and has room for this window.
CREATE OR REPLACE FUNCTION fn_technician_fits(
    p_technician_id INTEGER,
    p_scheduled     DATE,
    p_due           DATE
)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM technicians WHERE technician_id = p_technician_id)
       AND fn_technician_overlap_count(p_technician_id, p_scheduled, p_due)
           < (SELECT max_active_orders FROM technicians
               WHERE technician_id = p_technician_id);
$$ LANGUAGE sql STABLE;

-- Recommend the best-fit technician for a [scheduled, due] window: among those
-- whose schedule has room, prefer the least time-conflicted, then the least
-- loaded overall, then the highest certification. Optional specialization
-- filter. Returns NULL when nobody fits.
CREATE OR REPLACE FUNCTION fn_recommend_technician(
    p_scheduled      DATE,
    p_due            DATE,
    p_specialization VARCHAR DEFAULT NULL
)
RETURNS INTEGER AS $$
    SELECT t.technician_id
      FROM technicians t
      CROSS JOIN LATERAL (
          SELECT fn_technician_overlap_count(t.technician_id, p_scheduled, p_due)
                     AS overlap_cnt,
                 (SELECT COUNT(*) FROM work_orders w
                   WHERE w.technician_id = t.technician_id
                     AND w.status IN ('assigned','in_progress','on_hold'))
                     AS active_cnt
      ) c
     WHERE (p_specialization IS NULL
            OR t.specialization ILIKE '%' || p_specialization || '%')
       AND c.overlap_cnt < t.max_active_orders
     ORDER BY c.overlap_cnt ASC, c.active_cnt ASC,
              t.certification_level DESC, t.technician_id ASC
     LIMIT 1;
$$ LANGUAGE sql STABLE;

-- --- The procedure ---------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_create_work_order(
    VARCHAR, VARCHAR, TEXT, work_order_priority_enum, DATE, NUMERIC,
    VARCHAR, INTEGER);

CREATE OR REPLACE PROCEDURE sp_create_work_order(
    p_asset_tag         VARCHAR,
    p_title             VARCHAR,
    p_description       TEXT                      DEFAULT NULL,
    p_priority          work_order_priority_enum  DEFAULT 'medium',
    p_scheduled_date    DATE                      DEFAULT NULL,
    p_estimated_hours   NUMERIC                   DEFAULT NULL,
    p_employee_code     VARCHAR                   DEFAULT NULL,  -- explicit tech
    p_auto_assign       BOOLEAN                   DEFAULT TRUE,  -- pick best fit?
    p_specialization    VARCHAR                   DEFAULT NULL,  -- auto-assign filter
    INOUT p_new_work_order_id        INTEGER      DEFAULT NULL,
    INOUT p_assigned_employee_code   VARCHAR      DEFAULT NULL   -- who got it
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_asset_id      INTEGER;
    v_technician_id INTEGER := NULL;
    v_overlap       INTEGER;
    v_cap           SMALLINT;
    v_status        work_order_status_enum := 'open';
    v_scheduled     DATE;
    v_due           DATE;
    v_wo_number     VARCHAR(30);
BEGIN
    -- Resolve and validate the asset.
    SELECT asset_id INTO v_asset_id
      FROM assets WHERE asset_tag = p_asset_tag;
    IF v_asset_id IS NULL THEN
        RAISE EXCEPTION 'Asset with tag "%" does not exist.', p_asset_tag;
    END IF;

    -- Compute the order's planned window up front so we can fit it.
    v_scheduled := COALESCE(p_scheduled_date, CURRENT_DATE);
    v_due       := v_scheduled + fn_priority_sla_days(p_priority);

    IF p_employee_code IS NOT NULL THEN
        -- Explicit technician: must exist AND have room in this window.
        SELECT technician_id, max_active_orders
          INTO v_technician_id, v_cap
          FROM technicians WHERE employee_code = p_employee_code;

        IF v_technician_id IS NULL THEN
            RAISE EXCEPTION 'Technician with code "%" does not exist.',
                p_employee_code;
        END IF;

        v_overlap := fn_technician_overlap_count(v_technician_id, v_scheduled, v_due);
        IF v_overlap >= v_cap THEN
            RAISE EXCEPTION
                'Technician "%" cannot take this order: % overlapping active '
                'order(s) in the % .. % window already meets the cap of %.',
                p_employee_code, v_overlap, v_scheduled, v_due, v_cap;
        END IF;
        v_status := 'assigned';

    ELSIF p_auto_assign THEN
        -- No technician named: let the system pick the best schedule fit.
        v_technician_id := fn_recommend_technician(v_scheduled, v_due, p_specialization);
        IF v_technician_id IS NOT NULL THEN
            v_status := 'assigned';
        ELSE
            RAISE NOTICE
                'No technician fits the % .. % window; leaving order unassigned.',
                v_scheduled, v_due;
        END IF;
    END IF;

    -- Generate a readable, unique work-order number: WO-YYYY-NNNNNN
    v_wo_number := 'WO-' || to_char(CURRENT_DATE, 'YYYY') || '-' ||
                   lpad(nextval('work_orders_work_order_id_seq')::text, 6, '0');

    INSERT INTO work_orders (
        work_order_number, asset_id, technician_id, title, description,
        status, priority, scheduled_date, due_date, estimated_hours)
    VALUES (
        v_wo_number, v_asset_id, v_technician_id, p_title, p_description,
        v_status, p_priority, v_scheduled, v_due, p_estimated_hours)
    RETURNING work_order_id INTO p_new_work_order_id;

    SELECT employee_code INTO p_assigned_employee_code
      FROM technicians WHERE technician_id = v_technician_id;

    RAISE NOTICE 'Created work order % (id=%) for asset %, due %, assigned to %.',
        v_wo_number, p_new_work_order_id, p_asset_tag, v_due,
        COALESCE(p_assigned_employee_code, '(unassigned)');
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

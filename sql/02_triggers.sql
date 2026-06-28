-- =============================================================================
-- Power Utility Asset Management — Triggers
-- File: 02_triggers.sql
--
-- Trigger 1: trg_asset_last_inspected
--     When a work order transitions to 'completed', stamp the related asset's
--     last_inspected_date with the completion date and (if it was under
--     maintenance) put it back in service. Also advances any matching
--     preventive-maintenance schedule.
--
-- Trigger 2: trg_technician_availability
--     Keep technicians.is_available in sync with how many active work orders
--     each technician currently holds, relative to their max_active_orders.
--
-- Bonus: trg_work_order_audit logs status/assignment changes into
--     work_order_history, and trg_*_updated_at keeps updated_at fresh.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Generic updated_at maintenance.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_assets_updated_at     ON assets;
DROP TRIGGER IF EXISTS trg_technicians_updated_at ON technicians;
DROP TRIGGER IF EXISTS trg_work_orders_updated_at ON work_orders;
DROP TRIGGER IF EXISTS trg_schedules_updated_at   ON maintenance_schedules;

CREATE TRIGGER trg_assets_updated_at      BEFORE UPDATE ON assets
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_technicians_updated_at BEFORE UPDATE ON technicians
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_work_orders_updated_at BEFORE UPDATE ON work_orders
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();
CREATE TRIGGER trg_schedules_updated_at   BEFORE UPDATE ON maintenance_schedules
    FOR EACH ROW EXECUTE FUNCTION fn_set_updated_at();

-- =============================================================================
-- SLA helper: how many days a work order of a given priority gets to be
-- completed, measured from its scheduled (planned start) date.
--   critical -> 1 day   high -> 3 days   medium -> 14 days   low -> 30 days
-- IMMUTABLE so it can be used in defaults / generated expressions if desired.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_priority_sla_days(p_priority work_order_priority_enum)
RETURNS INTEGER AS $$
    SELECT CASE p_priority
               WHEN 'critical' THEN 1
               WHEN 'high'     THEN 3
               WHEN 'medium'   THEN 14
               WHEN 'low'      THEN 30
           END;
$$ LANGUAGE sql IMMUTABLE;

-- =============================================================================
-- BEFORE trigger on work_orders:
--   (a) On INSERT, if due_date was not supplied, derive it from the SLA:
--          due_date = COALESCE(scheduled_date, created date) + SLA(priority)
--   (b) On INSERT/UPDATE, if the order is being completed without a
--          completed_date, stamp it with today's date (keeps the
--          chk_completed_has_date constraint satisfied automatically).
-- Runs BEFORE the row is written, so it also satisfies table constraints.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_work_order_dates()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' AND NEW.due_date IS NULL THEN
        NEW.due_date := COALESCE(NEW.scheduled_date, CURRENT_DATE)
                        + fn_priority_sla_days(NEW.priority);
    END IF;

    IF NEW.status = 'completed' AND NEW.completed_date IS NULL THEN
        NEW.completed_date := CURRENT_DATE;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_work_order_dates ON work_orders;
CREATE TRIGGER trg_work_order_dates
    BEFORE INSERT OR UPDATE OF status, completed_date, due_date,
                              scheduled_date, priority ON work_orders
    FOR EACH ROW EXECUTE FUNCTION fn_work_order_dates();

-- =============================================================================
-- TRIGGER 1: Auto-update asset last_inspected_date on work-order completion.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_asset_last_inspected()
RETURNS TRIGGER AS $$
DECLARE
    v_completed DATE;
BEGIN
    -- Only react when the order has just become 'completed'.
    IF NEW.status = 'completed'
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM 'completed') THEN

        v_completed := COALESCE(NEW.completed_date, CURRENT_DATE);

        -- Stamp the asset's inspection date and restore service if it was down
        -- specifically for maintenance.
        UPDATE assets
           SET last_inspected_date = v_completed,
               status = CASE WHEN status = 'under_maintenance'
                             THEN 'in_service' ELSE status END
         WHERE asset_id = NEW.asset_id;

        -- Advance any active preventive-maintenance schedule for this asset
        -- whose task matches the work order title (best-effort coupling).
        UPDATE maintenance_schedules
           SET last_performed_date = v_completed,
               next_due_date       = v_completed + (interval_days || ' days')::interval
         WHERE asset_id = NEW.asset_id
           AND is_active = TRUE
           AND (NEW.title ILIKE '%' || task_name || '%'
                OR task_name ILIKE '%' || NEW.title || '%');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_asset_last_inspected ON work_orders;
CREATE TRIGGER trg_asset_last_inspected
    AFTER INSERT OR UPDATE OF status, completed_date ON work_orders
    FOR EACH ROW EXECUTE FUNCTION fn_asset_last_inspected();

-- =============================================================================
-- TRIGGER 2: Auto-update technician availability from active workload.
--   "Active" = work orders in status assigned / in_progress / on_hold.
--   A technician is available when they hold fewer active orders than their
--   max_active_orders cap. Recomputes for both the old and new technician on
--   reassignment.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_recompute_technician_availability(p_technician_id INTEGER)
RETURNS VOID AS $$
DECLARE
    v_active INTEGER;
    v_cap    SMALLINT;
BEGIN
    IF p_technician_id IS NULL THEN
        RETURN;
    END IF;

    SELECT COUNT(*) INTO v_active
      FROM work_orders
     WHERE technician_id = p_technician_id
       AND status IN ('assigned', 'in_progress', 'on_hold');

    SELECT max_active_orders INTO v_cap
      FROM technicians
     WHERE technician_id = p_technician_id;

    UPDATE technicians
       SET is_available = (v_active < v_cap)
     WHERE technician_id = p_technician_id;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION fn_technician_availability()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        PERFORM fn_recompute_technician_availability(OLD.technician_id);
        RETURN OLD;
    END IF;

    -- On reassignment recompute both the previous and the new technician.
    IF TG_OP = 'UPDATE'
       AND OLD.technician_id IS DISTINCT FROM NEW.technician_id THEN
        PERFORM fn_recompute_technician_availability(OLD.technician_id);
    END IF;

    PERFORM fn_recompute_technician_availability(NEW.technician_id);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_technician_availability ON work_orders;
CREATE TRIGGER trg_technician_availability
    AFTER INSERT OR UPDATE OF technician_id, status OR DELETE ON work_orders
    FOR EACH ROW EXECUTE FUNCTION fn_technician_availability();

-- =============================================================================
-- BONUS TRIGGER: Audit work-order status / assignment changes into history.
-- =============================================================================
CREATE OR REPLACE FUNCTION fn_work_order_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO work_order_history (
            work_order_id, old_status, new_status,
            old_technician_id, new_technician_id, change_note)
        VALUES (NEW.work_order_id, NULL, NEW.status,
                NULL, NEW.technician_id, 'Work order created');
        RETURN NEW;
    END IF;

    -- Only log when something audit-worthy actually changed.
    IF OLD.status IS DISTINCT FROM NEW.status
       OR OLD.technician_id IS DISTINCT FROM NEW.technician_id THEN
        INSERT INTO work_order_history (
            work_order_id, old_status, new_status,
            old_technician_id, new_technician_id, change_note)
        VALUES (NEW.work_order_id, OLD.status, NEW.status,
                OLD.technician_id, NEW.technician_id,
                'Status/assignment change');
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_work_order_audit ON work_orders;
CREATE TRIGGER trg_work_order_audit
    AFTER INSERT OR UPDATE OF status, technician_id ON work_orders
    FOR EACH ROW EXECUTE FUNCTION fn_work_order_audit();

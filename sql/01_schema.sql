-- =============================================================================
-- Power Utility Asset Management — Schema
-- File: 01_schema.sql
-- Target: PostgreSQL 13+
--
-- Defines the 5 core tables:
--   1. assets                 — physical grid equipment
--   2. technicians            — field personnel
--   3. work_orders            — maintenance/repair jobs
--   4. maintenance_schedules  — recurring preventive-maintenance plans
--   5. work_order_history     — append-only audit trail of work-order changes
-- =============================================================================

-- Run on a clean database. Drop in reverse-dependency order so reruns are safe.
DROP TABLE IF EXISTS work_order_history     CASCADE;
DROP TABLE IF EXISTS maintenance_schedules  CASCADE;
DROP TABLE IF EXISTS work_orders            CASCADE;
DROP TABLE IF EXISTS technicians            CASCADE;
DROP TABLE IF EXISTS assets                 CASCADE;

-- -----------------------------------------------------------------------------
-- Enumerated domains. Using ENUMs keeps status/category values consistent
-- and makes the schema self-documenting.
-- -----------------------------------------------------------------------------
DROP TYPE IF EXISTS asset_status_enum        CASCADE;
DROP TYPE IF EXISTS asset_type_enum          CASCADE;
DROP TYPE IF EXISTS work_order_status_enum   CASCADE;
DROP TYPE IF EXISTS work_order_priority_enum CASCADE;

CREATE TYPE asset_type_enum AS ENUM (
    'transformer', 'circuit_breaker', 'transmission_line', 'substation',
    'switchgear', 'capacitor_bank', 'recloser', 'meter', 'pole', 'regulator'
);

CREATE TYPE asset_status_enum AS ENUM (
    'in_service', 'out_of_service', 'under_maintenance', 'decommissioned'
);

CREATE TYPE work_order_status_enum AS ENUM (
    'open', 'assigned', 'in_progress', 'on_hold', 'completed', 'cancelled'
);

CREATE TYPE work_order_priority_enum AS ENUM (
    'low', 'medium', 'high', 'critical'
);

-- -----------------------------------------------------------------------------
-- 1. assets — every piece of trackable physical equipment on the grid.
-- -----------------------------------------------------------------------------
CREATE TABLE assets (
    asset_id            SERIAL PRIMARY KEY,
    asset_tag           VARCHAR(40)  NOT NULL UNIQUE,      -- field-stenciled tag
    name                VARCHAR(120) NOT NULL,
    asset_type          asset_type_enum NOT NULL,
    manufacturer        VARCHAR(120),
    model_number        VARCHAR(80),
    voltage_rating_kv   NUMERIC(8,2),                      -- nominal kV rating
    location            VARCHAR(200) NOT NULL,             -- substation / feeder
    latitude            NUMERIC(9,6),
    longitude           NUMERIC(9,6),
    install_date        DATE,
    status              asset_status_enum NOT NULL DEFAULT 'in_service',
    -- last_inspected_date is maintained by a trigger when a related work order
    -- is completed; it is not normally written to directly.
    last_inspected_date DATE,
    criticality         SMALLINT NOT NULL DEFAULT 3
                          CHECK (criticality BETWEEN 1 AND 5),  -- 1=low, 5=vital
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  assets IS 'Physical grid equipment tracked for maintenance.';
COMMENT ON COLUMN assets.last_inspected_date IS
    'Auto-maintained by trg_asset_last_inspected when a work order completes.';

-- -----------------------------------------------------------------------------
-- 2. technicians — field crew who execute work orders.
-- -----------------------------------------------------------------------------
CREATE TABLE technicians (
    technician_id     SERIAL PRIMARY KEY,
    employee_code     VARCHAR(20)  NOT NULL UNIQUE,
    first_name        VARCHAR(60)  NOT NULL,
    last_name         VARCHAR(60)  NOT NULL,
    email             VARCHAR(160) UNIQUE,
    phone             VARCHAR(30),
    specialization    VARCHAR(80),                          -- e.g. 'high voltage'
    certification_level SMALLINT NOT NULL DEFAULT 1
                          CHECK (certification_level BETWEEN 1 AND 5),
    -- is_available is auto-maintained by a trigger based on active assignments.
    is_available      BOOLEAN NOT NULL DEFAULT TRUE,
    max_active_orders SMALLINT NOT NULL DEFAULT 3
                          CHECK (max_active_orders > 0),
    hire_date         DATE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE  technicians IS 'Field technicians who perform work orders.';
COMMENT ON COLUMN technicians.is_available IS
    'Auto-maintained by trg_technician_availability from active assignments.';

-- -----------------------------------------------------------------------------
-- 3. work_orders — a unit of maintenance/repair work against one asset.
-- -----------------------------------------------------------------------------
CREATE TABLE work_orders (
    work_order_id     SERIAL PRIMARY KEY,
    work_order_number VARCHAR(30) NOT NULL UNIQUE,          -- human reference
    asset_id          INTEGER NOT NULL
                          REFERENCES assets(asset_id) ON DELETE CASCADE,
    technician_id     INTEGER
                          REFERENCES technicians(technician_id) ON DELETE SET NULL,
    title             VARCHAR(160) NOT NULL,
    description       TEXT,
    status            work_order_status_enum   NOT NULL DEFAULT 'open',
    priority          work_order_priority_enum NOT NULL DEFAULT 'medium',
    scheduled_date    DATE,                                 -- planned start date
    -- due_date is the SLA deadline. Auto-filled on INSERT by
    -- trg_work_order_dates from priority + scheduled_date when not supplied.
    due_date          DATE,
    completed_date    DATE,
    estimated_hours   NUMERIC(6,2) CHECK (estimated_hours >= 0),
    actual_hours      NUMERIC(6,2) CHECK (actual_hours   >= 0),
    cost              NUMERIC(12,2) CHECK (cost >= 0),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- A completed order must carry a completion date.
    CONSTRAINT chk_completed_has_date
        CHECK (status <> 'completed' OR completed_date IS NOT NULL),
    -- The deadline cannot precede the planned start.
    CONSTRAINT chk_due_after_scheduled
        CHECK (due_date IS NULL OR scheduled_date IS NULL
               OR due_date >= scheduled_date)
);

COMMENT ON TABLE work_orders IS 'Maintenance / repair jobs scheduled against assets.';

-- -----------------------------------------------------------------------------
-- 4. maintenance_schedules — recurring preventive-maintenance definitions.
-- -----------------------------------------------------------------------------
CREATE TABLE maintenance_schedules (
    schedule_id        SERIAL PRIMARY KEY,
    asset_id           INTEGER NOT NULL
                          REFERENCES assets(asset_id) ON DELETE CASCADE,
    task_name          VARCHAR(160) NOT NULL,
    description        TEXT,
    interval_days      INTEGER NOT NULL CHECK (interval_days > 0),
    last_performed_date DATE,
    next_due_date      DATE NOT NULL,
    default_priority   work_order_priority_enum NOT NULL DEFAULT 'medium',
    is_active          BOOLEAN NOT NULL DEFAULT TRUE,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE maintenance_schedules IS
    'Recurring preventive-maintenance plans; next_due_date drives the overdue view.';

-- -----------------------------------------------------------------------------
-- 5. work_order_history — append-only log of work-order state changes.
--    Written by the work-order audit trigger; never updated/deleted in normal use.
-- -----------------------------------------------------------------------------
CREATE TABLE work_order_history (
    history_id        BIGSERIAL PRIMARY KEY,
    work_order_id     INTEGER NOT NULL
                          REFERENCES work_orders(work_order_id) ON DELETE CASCADE,
    old_status        work_order_status_enum,
    new_status        work_order_status_enum,
    old_technician_id INTEGER,
    new_technician_id INTEGER,
    changed_by        VARCHAR(80) NOT NULL DEFAULT CURRENT_USER,
    change_note       TEXT,
    changed_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE work_order_history IS
    'Append-only audit trail of work-order status/assignment changes.';

-- -----------------------------------------------------------------------------
-- Indexes for the common access paths (lookups, joins, view predicates).
-- -----------------------------------------------------------------------------
CREATE INDEX idx_work_orders_asset        ON work_orders (asset_id);
CREATE INDEX idx_work_orders_technician   ON work_orders (technician_id);
CREATE INDEX idx_work_orders_status       ON work_orders (status);
CREATE INDEX idx_work_orders_scheduled    ON work_orders (scheduled_date);
CREATE INDEX idx_work_orders_due          ON work_orders (due_date);
CREATE INDEX idx_schedules_asset          ON maintenance_schedules (asset_id);
CREATE INDEX idx_schedules_next_due       ON maintenance_schedules (next_due_date);
CREATE INDEX idx_history_work_order        ON work_order_history (work_order_id);
CREATE INDEX idx_assets_status            ON assets (status);
CREATE INDEX idx_assets_type              ON assets (asset_type);

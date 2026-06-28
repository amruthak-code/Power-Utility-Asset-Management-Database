# Power Utility Asset Management Database

A PostgreSQL database for managing electric-utility grid assets, the technicians
who maintain them, work orders, recurring maintenance schedules, and a full
audit trail — plus a Python ETL pipeline to bulk-load assets from CSV.

## What's inside

```
Power utility/
├── README.md                  # this file
├── run_all.sql                # runs every SQL file in order
├── sql/
│   ├── 01_schema.sql          # 5 tables + enums + indexes
│   ├── 02_triggers.sql        # 2 core triggers (+ audit & updated_at)
│   ├── 03_procedures.sql      # create work order + maintenance report
│   ├── 04_views.sql           # overdue assets + technician workload
│   └── 05_seed_data.sql       # 12 assets, 5 techs, 20 work orders, schedules
├── etl/
│   ├── load_assets.py         # CSV → PostgreSQL ETL (validating + idempotent)
│   └── requirements.txt
├── data/
│   └── assets_import.csv      # sample input for the ETL
└── docs/
    └── ERD.md                 # entity-relationship diagram + documentation
```

## Data model (5 tables)

| Table | Purpose |
|-------|---------|
| `assets` | Physical grid equipment (transformers, breakers, lines, …). |
| `technicians` | Field crew who execute work. |
| `work_orders` | Maintenance/repair jobs against an asset, optionally assigned to a technician. |
| `maintenance_schedules` | Recurring preventive-maintenance plans per asset. |
| `work_order_history` | Append-only audit log of work-order changes. |

See [docs/ERD.md](docs/ERD.md) for the full diagram and relationship details.

## Quick start

### 1. Create the database and load everything

```bash
createdb power_utility
psql -d power_utility -f run_all.sql
```

That creates the schema, triggers, procedures, views, and seed data in one go.

### 2. Try the views

```sql
-- Assets past due for maintenance, most urgent first
SELECT asset_tag, task_name, days_overdue, urgency_score
FROM vw_overdue_assets;

-- Technician load and utilization
SELECT technician_name, active_orders, completed_orders, utilization_pct, is_available
FROM vw_technician_workload;

-- Work orders past their SLA due date
SELECT work_order_number, priority, due_date, days_late, employee_code
FROM vw_overdue_work_orders;
```

### 3. Call the stored procedures

```sql
-- Auto-assign: the system computes the [scheduled_date, due_date] window from
-- the priority SLA and picks the best-fit technician whose schedule has room.
CALL sp_create_work_order(
    p_asset_tag       => 'TX-0001',
    p_title           => 'Emergency oil top-up',
    p_description     => 'Low oil alarm',
    p_priority        => 'critical',          -- => due in 1 day
    p_scheduled_date  => CURRENT_DATE + 1,
    p_estimated_hours => 3,
    p_employee_code   => NULL,                 -- no explicit tech...
    p_auto_assign     => TRUE,                 -- ...so the system chooses
    p_specialization  => NULL,                 -- optional skill filter
    p_new_work_order_id      => NULL,
    p_assigned_employee_code => NULL           -- INOUT: who got the order
);

-- Or name a technician explicitly; it is rejected if their schedule can't fit
-- the order's window (too many overlapping active deadlines).
CALL sp_create_work_order('TX-0001','Oil top-up',NULL,'high',
     CURRENT_DATE+1, 3, 'TECH-001', TRUE, NULL, NULL, NULL);

-- Maintenance report for a date window
SELECT * FROM fn_generate_maintenance_report(CURRENT_DATE - 365, CURRENT_DATE);
```

### How dates and assignment work

| Field | How it's set |
|-------|--------------|
| `scheduled_date` | Planned start; supplied at creation (defaults to today). |
| `due_date` | SLA deadline auto-derived as `scheduled_date + SLA(priority)` — critical 1d, high 3d, medium 14d, low 30d. |
| `completed_date` | Auto-stamped with today when an order is marked `completed`. |

When assigning, each active order occupies a `[scheduled_date, due_date]`
window. A technician can take a new order only if their **overlapping** active
orders are fewer than `max_active_orders`, so deadlines don't collide. Past-due
active orders show up in the `vw_overdue_work_orders` view.

## ETL: load assets from CSV

The ETL reads a CSV, validates and cleans every row (enum checks, number/date
parsing, required fields), then UPSERTs by `asset_tag` so it is safe to re-run.

```bash
cd "Power utility"
python3 -m venv .venv && source .venv/bin/activate
pip install -r etl/requirements.txt

# point at your database (or set PGHOST/PGDATABASE/PGUSER/... individually)
export DATABASE_URL="postgresql://localhost:5432/power_utility"

# validate only, no writes
python etl/load_assets.py --csv data/assets_import.csv --dry-run

# load for real
python etl/load_assets.py --csv data/assets_import.csv
```

The sample `data/assets_import.csv` adds 10 more assets to the 12 seeded ones.

## Triggers in action

- Creating a work order auto-derives its `due_date` from the priority SLA; no
  need to compute deadlines by hand.
- Completing a work order (`status = 'completed'`) auto-stamps `completed_date`,
  the asset's `last_inspected_date`, returns `under_maintenance` assets to
  service, and advances the matching maintenance schedule.
- Assigning/closing work orders automatically flips a technician's
  `is_available` flag based on their active workload vs. capacity.
- Every status/assignment change is logged to `work_order_history`.

## Requirements

- PostgreSQL 13 or newer (`psql`, `createdb`)
- Python 3.9+ with `psycopg2-binary` (for the ETL only)

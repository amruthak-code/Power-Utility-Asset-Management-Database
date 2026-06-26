# Power Utility Asset Management — Entity Relationship Diagram (ERD)

This document describes the data model: the five tables, their columns, and the
relationships between them.

---

## 1. Entity Relationship Diagram

The diagram below uses [Mermaid](https://mermaid.js.org/) ER syntax. It renders
automatically on GitHub and in most Markdown viewers. A plain-text version
follows for environments that do not render Mermaid.

```mermaid
erDiagram
    ASSETS ||--o{ WORK_ORDERS : "is serviced by"
    ASSETS ||--o{ MAINTENANCE_SCHEDULES : "has plan"
    TECHNICIANS ||--o{ WORK_ORDERS : "is assigned"
    WORK_ORDERS ||--o{ WORK_ORDER_HISTORY : "logs changes"

    ASSETS {
        int          asset_id PK
        varchar      asset_tag UK
        varchar      name
        enum         asset_type
        varchar      manufacturer
        varchar      model_number
        numeric      voltage_rating_kv
        varchar      location
        numeric      latitude
        numeric      longitude
        date         install_date
        enum         status
        date         last_inspected_date "trigger-maintained"
        smallint     criticality "1-5"
        timestamptz  created_at
        timestamptz  updated_at
    }

    TECHNICIANS {
        int          technician_id PK
        varchar      employee_code UK
        varchar      first_name
        varchar      last_name
        varchar      email UK
        varchar      phone
        varchar      specialization
        smallint     certification_level "1-5"
        boolean      is_available "trigger-maintained"
        smallint     max_active_orders
        date         hire_date
        timestamptz  created_at
        timestamptz  updated_at
    }

    WORK_ORDERS {
        int          work_order_id PK
        varchar      work_order_number UK
        int          asset_id FK
        int          technician_id FK "nullable"
        varchar      title
        text         description
        enum         status
        enum         priority
        date         scheduled_date
        date         completed_date
        numeric      estimated_hours
        numeric      actual_hours
        numeric      cost
        timestamptz  created_at
        timestamptz  updated_at
    }

    MAINTENANCE_SCHEDULES {
        int          schedule_id PK
        int          asset_id FK
        varchar      task_name
        text         description
        int          interval_days
        date         last_performed_date
        date         next_due_date
        enum         default_priority
        boolean      is_active
        timestamptz  created_at
        timestamptz  updated_at
    }

    WORK_ORDER_HISTORY {
        bigint       history_id PK
        int          work_order_id FK
        enum         old_status
        enum         new_status
        int          old_technician_id
        int          new_technician_id
        varchar      changed_by
        text         change_note
        timestamptz  changed_at
    }
```

### Plain-text relationship diagram

```
                          +-------------------------+
                          |       TECHNICIANS       |
                          |-------------------------|
                          | PK technician_id        |
                          | UK employee_code        |
                          |    is_available (trig)  |
                          +-----------+-------------+
                                      | 1
                                      |
                                      | assigned to (0..N)
                                      v N
+----------------------+        +-----+----------------+        +-----------------------+
|       ASSETS         | 1    N |     WORK_ORDERS      | 1    N |  WORK_ORDER_HISTORY   |
|----------------------|--------|----------------------|--------|-----------------------|
| PK asset_id          | serviced  | PK work_order_id  | logs   | PK history_id         |
| UK asset_tag         |  by    | UK work_order_number| changes| FK work_order_id      |
|    last_inspected    |        | FK asset_id         |        |    old_status         |
|       (trigger)      |        | FK technician_id    |        |    new_status         |
+----------+-----------+        +---------------------+        +-----------------------+
           | 1
           |
           | has plan (0..N)
           v N
+----------------------+
| MAINTENANCE_SCHEDULES|
|----------------------|
| PK schedule_id       |
| FK asset_id          |
|    next_due_date     |
+----------------------+
```

---

## 2. Tables and Relationships

### 2.1 `assets`
The central entity: every physical, trackable piece of grid equipment
(transformers, breakers, lines, substations, etc.).

- **Primary key:** `asset_id`
- **Natural key:** `asset_tag` (the field-stenciled tag, unique)
- `last_inspected_date` is **not** written by hand — a trigger updates it when a
  related work order is completed.

### 2.2 `technicians`
Field crew who carry out work orders.

- **Primary key:** `technician_id`
- **Natural key:** `employee_code` (unique)
- `is_available` is **trigger-maintained** based on how many active work orders
  the technician holds versus `max_active_orders`.

### 2.3 `work_orders`
A single maintenance or repair job. This is the busiest table and the hub of the
operational model.

- **Primary key:** `work_order_id`
- **Foreign keys:**
  - `asset_id` → `assets(asset_id)` — **required**, `ON DELETE CASCADE`
  - `technician_id` → `technicians(technician_id)` — **nullable** (an open,
    unassigned order has no technician), `ON DELETE SET NULL`

### 2.4 `maintenance_schedules`
Recurring preventive-maintenance plans for an asset. `next_due_date` drives the
overdue-assets view.

- **Primary key:** `schedule_id`
- **Foreign key:** `asset_id` → `assets(asset_id)`, `ON DELETE CASCADE`

### 2.5 `work_order_history`
Append-only audit trail. Every status or assignment change on a work order
writes a row here (via a trigger).

- **Primary key:** `history_id`
- **Foreign key:** `work_order_id` → `work_orders(work_order_id)`,
  `ON DELETE CASCADE`

---

## 3. Relationship Summary

| # | Parent (one) | Child (many) | Foreign key | Cardinality | On delete | Meaning |
|---|--------------|--------------|-------------|-------------|-----------|---------|
| 1 | `assets` | `work_orders` | `work_orders.asset_id` | 1 : N | CASCADE | Each asset can have many work orders; every work order targets exactly one asset. |
| 2 | `assets` | `maintenance_schedules` | `maintenance_schedules.asset_id` | 1 : N | CASCADE | Each asset can have many recurring maintenance plans. |
| 3 | `technicians` | `work_orders` | `work_orders.technician_id` | 1 : N (optional) | SET NULL | A technician may be assigned many work orders; a work order may be unassigned. |
| 4 | `work_orders` | `work_order_history` | `work_order_history.work_order_id` | 1 : N | CASCADE | Each work order accumulates many history (audit) rows. |

**Cardinality notation:** `1 : N` means one parent row relates to zero-or-more
child rows. Relationship 3 is *optional* on the child side because
`technician_id` is nullable (backlog/open orders have no technician yet).

---

## 4. Automated Behavior (Triggers)

These keep derived columns and the audit trail correct without application code:

| Trigger | Fires on | Effect |
|---------|----------|--------|
| `trg_asset_last_inspected` | `work_orders` INSERT/UPDATE when status becomes `completed` | Sets `assets.last_inspected_date`, restores `under_maintenance` assets to `in_service`, and advances the matching `maintenance_schedules.next_due_date`. |
| `trg_technician_availability` | `work_orders` INSERT/UPDATE/DELETE | Recomputes `technicians.is_available` from the count of active orders vs. `max_active_orders`. |
| `trg_work_order_audit` | `work_orders` INSERT/UPDATE of status or technician | Writes a row into `work_order_history`. |
| `trg_*_updated_at` | UPDATE on each table | Refreshes the `updated_at` timestamp. |

---

## 5. Views

| View | Purpose |
|------|---------|
| `vw_overdue_assets` | Assets whose active maintenance schedule is past due, ranked by an urgency score (`days_overdue × criticality`). |
| `vw_technician_workload` | Per-technician active/completed counts, hours logged, and utilization (% of capacity). |

## 6. Stored Procedures / Functions

| Routine | Type | Purpose |
|---------|------|---------|
| `sp_create_work_order(...)` | PROCEDURE | Validates the asset/technician, checks technician capacity, generates a `WO-YYYY-NNNNNN` number, inserts the order, and returns the new id. |
| `fn_generate_maintenance_report(start, end)` | FUNCTION → TABLE | Per-asset summary over a date window: completed orders, open orders, total cost, hours, average resolution days. |

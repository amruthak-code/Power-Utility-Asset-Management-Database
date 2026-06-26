-- =============================================================================
-- Power Utility Asset Management — Seed Data
-- File: 05_seed_data.sql
--
-- Loads a representative dataset:
--   * 12 assets
--   *  5 technicians
--   * 10 maintenance schedules (several intentionally overdue for the view)
--   * 20 work orders (mix of completed / active / open)
--
-- Note: inserting work orders fires the audit, availability, and
-- last-inspected triggers, so history/availability/inspection dates populate
-- automatically. Run AFTER 01–04.
-- =============================================================================

-- Clear existing data so the script is rerunnable. TRUNCATE … RESTART IDENTITY
-- resets the SERIAL sequences; CASCADE clears dependent rows.
TRUNCATE work_order_history, work_orders, maintenance_schedules,
         technicians, assets RESTART IDENTITY CASCADE;

-- -----------------------------------------------------------------------------
-- Technicians (5)
-- -----------------------------------------------------------------------------
INSERT INTO technicians
    (employee_code, first_name, last_name, email, phone, specialization,
     certification_level, max_active_orders, hire_date)
VALUES
 ('TECH-001','Maria','Gonzalez','maria.gonzalez@util.example','408-555-0101',
    'high voltage transformers', 5, 4, '2015-03-12'),
 ('TECH-002','James','Okafor','james.okafor@util.example','408-555-0102',
    'circuit breakers & switchgear', 4, 3, '2017-07-01'),
 ('TECH-003','Wei','Zhang','wei.zhang@util.example','408-555-0103',
    'transmission lines', 4, 3, '2018-01-22'),
 ('TECH-004','Sarah','Mueller','sarah.mueller@util.example','408-555-0104',
    'protection & metering', 3, 3, '2020-09-15'),
 ('TECH-005','David','Nguyen','david.nguyen@util.example','408-555-0105',
    'substation general', 2, 2, '2022-04-04');

-- -----------------------------------------------------------------------------
-- Assets (12)
-- -----------------------------------------------------------------------------
INSERT INTO assets
    (asset_tag, name, asset_type, manufacturer, model_number, voltage_rating_kv,
     location, latitude, longitude, install_date, status, criticality)
VALUES
 ('TX-0001','Main Power Transformer #1','transformer','ABB','TrafoStar-230',230.00,
    'Alviso Substation', 37.426400,-121.975600,'2009-06-15','in_service',5),
 ('TX-0002','Distribution Transformer #2','transformer','Siemens','GEAFOL-25',25.00,
    'Berryessa Substation', 37.385900,-121.864300,'2012-11-03','in_service',4),
 ('CB-0101','Feeder Circuit Breaker A','circuit_breaker','Schneider','MasterPact-NW',69.00,
    'Alviso Substation', 37.426410,-121.975610,'2011-02-20','in_service',4),
 ('CB-0102','Feeder Circuit Breaker B','circuit_breaker','Eaton','VCP-W',69.00,
    'Berryessa Substation', 37.385910,-121.864310,'2014-08-09','under_maintenance',3),
 ('TL-0201','Transmission Line North Span','transmission_line','Southwire','ACSR-Drake',230.00,
    'North Corridor MP 12-18', 37.500000,-121.900000,'2008-05-01','in_service',5),
 ('TL-0202','Transmission Line East Span','transmission_line','General Cable','ACSR-Hawk',115.00,
    'East Corridor MP 3-9', 37.360000,-121.800000,'2013-10-12','in_service',4),
 ('SW-0301','Switchgear Lineup 1','switchgear','ABB','UniGear-ZS1',25.00,
    'Berryessa Substation', 37.385920,-121.864320,'2016-03-30','in_service',3),
 ('CAP-0401','Capacitor Bank #1','capacitor_bank','GE','CapBank-DX',12.47,
    'Evergreen Substation', 37.300000,-121.770000,'2017-09-18','in_service',2),
 ('RC-0501','Pole-Top Recloser 5','recloser','S&C','IntelliRupter',12.47,
    'Evergreen Feeder 5', 37.301000,-121.771000,'2019-12-05','in_service',3),
 ('RG-0601','Voltage Regulator 6','regulator','Eaton','CL-7',12.47,
    'Coyote Feeder 2', 37.250000,-121.760000,'2018-06-22','in_service',2),
 ('SS-0701','Evergreen Substation Bus','substation','Multiple','BUS-A',115.00,
    'Evergreen Substation', 37.300100,-121.770100,'2007-01-10','in_service',5),
 ('MT-0801','Revenue Meter Bank 8','meter','Itron','OpenWay-Riva',0.48,
    'Coyote Substation', 37.250100,-121.760100,'2021-03-14','in_service',1);

-- -----------------------------------------------------------------------------
-- Maintenance schedules (10). Past next_due_date => shows in vw_overdue_assets.
-- Dates are relative to CURRENT_DATE so the demo stays meaningful over time.
-- -----------------------------------------------------------------------------
INSERT INTO maintenance_schedules
    (asset_id, task_name, description, interval_days, last_performed_date,
     next_due_date, default_priority, is_active)
VALUES
 (1,'Annual DGA oil sample','Dissolved gas analysis of transformer oil',365,
     CURRENT_DATE-400, CURRENT_DATE-35,'high',TRUE),         -- overdue
 (1,'Bushing inspection','Visual + thermal bushing check',180,
     CURRENT_DATE-200, CURRENT_DATE-20,'medium',TRUE),        -- overdue
 (2,'Annual DGA oil sample','Dissolved gas analysis of transformer oil',365,
     CURRENT_DATE-300, CURRENT_DATE+65,'high',TRUE),          -- upcoming
 (3,'Breaker timing test','SF6 breaker contact timing test',365,
     CURRENT_DATE-380, CURRENT_DATE-15,'high',TRUE),          -- overdue
 (4,'Breaker overhaul','Full mechanism overhaul',730,
     CURRENT_DATE-750, CURRENT_DATE-20,'critical',TRUE),      -- overdue
 (5,'Line patrol','Aerial right-of-way patrol',180,
     CURRENT_DATE-170, CURRENT_DATE+10,'medium',TRUE),        -- upcoming
 (7,'Switchgear PM','Clean, torque, and IR scan',365,
     CURRENT_DATE-200, CURRENT_DATE+165,'medium',TRUE),       -- upcoming
 (8,'Capacitor bank check','Fuse and unit balance check',365,
     CURRENT_DATE-420, CURRENT_DATE-55,'low',TRUE),           -- overdue
 (9,'Recloser battery test','Control battery load test',180,
     CURRENT_DATE-185, CURRENT_DATE-5,'medium',TRUE),         -- overdue
 (11,'Substation ground test','Ground grid resistance test',1095,
     CURRENT_DATE-1100, CURRENT_DATE-30,'high',TRUE);         -- overdue

-- -----------------------------------------------------------------------------
-- Work orders (20). Mix of completed, in_progress, assigned, on_hold, open.
-- work_order_number is explicit here (the sp_create_work_order procedure
-- generates them automatically for app-created orders).
-- -----------------------------------------------------------------------------
INSERT INTO work_orders
    (work_order_number, asset_id, technician_id, title, description, status,
     priority, scheduled_date, completed_date, estimated_hours, actual_hours, cost)
VALUES
 -- Completed history (drives the maintenance report + last_inspected trigger)
 ('WO-2024-000001', 1,1,'Annual DGA oil sample','Routine oil DGA','completed',
    'high',     CURRENT_DATE-410, CURRENT_DATE-405, 4.0, 4.5, 1250.00),
 ('WO-2024-000002', 3,2,'Breaker timing test','Annual timing test','completed',
    'high',     CURRENT_DATE-385, CURRENT_DATE-380, 6.0, 5.5, 2100.00),
 ('WO-2024-000003', 5,3,'Line patrol','Spring right-of-way patrol','completed',
    'medium',   CURRENT_DATE-175, CURRENT_DATE-172, 8.0, 7.0, 1800.00),
 ('WO-2024-000004', 8,4,'Capacitor bank check','Balance + fuse check','completed',
    'low',      CURRENT_DATE-425, CURRENT_DATE-422, 3.0, 3.0,  650.00),
 ('WO-2024-000005', 2,1,'Bushing inspection','Thermal bushing scan','completed',
    'medium',   CURRENT_DATE-90,  CURRENT_DATE-88,  3.0, 2.5,  900.00),
 ('WO-2025-000006', 11,5,'Substation ground test','Triennial ground grid','completed',
    'high',     CURRENT_DATE-60,  CURRENT_DATE-58,  10.0, 9.5, 3400.00),
 ('WO-2025-000007', 7,2,'Switchgear PM','Clean and IR scan','completed',
    'medium',   CURRENT_DATE-45,  CURRENT_DATE-44,  5.0, 5.0, 1500.00),
 ('WO-2025-000008', 9,4,'Recloser firmware update','Apply vendor patch','completed',
    'medium',   CURRENT_DATE-30,  CURRENT_DATE-29,  2.0, 1.5,  400.00),

 -- Active: in_progress
 ('WO-2025-000009', 4,2,'Breaker overhaul','Full mechanism overhaul','in_progress',
    'critical', CURRENT_DATE-3,   NULL,            16.0, NULL, NULL),
 ('WO-2025-000010', 1,1,'Bushing inspection','Follow-up bushing thermal','in_progress',
    'high',     CURRENT_DATE-1,   NULL,             3.0, NULL, NULL),

 -- Active: assigned
 ('WO-2025-000011', 5,3,'Conductor splice repair','Repair hot splice MP14','assigned',
    'high',     CURRENT_DATE+2,   NULL,             6.0, NULL, NULL),
 ('WO-2025-000012', 6,3,'Insulator replacement','Replace cracked insulators','assigned',
    'medium',   CURRENT_DATE+5,   NULL,             5.0, NULL, NULL),
 ('WO-2025-000013', 12,4,'Meter accuracy test','Annual revenue meter test','assigned',
    'low',      CURRENT_DATE+7,   NULL,             2.0, NULL, NULL),
 ('WO-2025-000014', 10,5,'Regulator tap audit','Inspect tap changer','assigned',
    'medium',   CURRENT_DATE+4,   NULL,             3.0, NULL, NULL),

 -- Active: on_hold (waiting on parts)
 ('WO-2025-000015', 4,2,'Replace SF6 density monitor','Awaiting part','on_hold',
    'high',     CURRENT_DATE+1,   NULL,             4.0, NULL, NULL),

 -- Open / unassigned (backlog)
 ('WO-2025-000016', 1,NULL,'Annual DGA oil sample','Next-year oil DGA','open',
    'high',     CURRENT_DATE+30,  NULL,             4.0, NULL, NULL),
 ('WO-2025-000017', 8,NULL,'Capacitor bank check','Annual balance check','open',
    'low',      CURRENT_DATE+20,  NULL,             3.0, NULL, NULL),
 ('WO-2025-000018', 9,NULL,'Recloser battery test','Semi-annual load test','open',
    'medium',   CURRENT_DATE+12,  NULL,             2.0, NULL, NULL),
 ('WO-2025-000019', 11,NULL,'Bus thermography','IR scan of substation bus','open',
    'medium',   CURRENT_DATE+25,  NULL,             4.0, NULL, NULL),
 ('WO-2025-000020', 3,NULL,'Breaker timing test','Next annual timing test','open',
    'high',     CURRENT_DATE+40,  NULL,             6.0, NULL, NULL);

-- -----------------------------------------------------------------------------
-- Quick sanity output after load.
-- -----------------------------------------------------------------------------
DO $$
DECLARE a INT; t INT; w INT; h INT; s INT;
BEGIN
    SELECT COUNT(*) INTO a FROM assets;
    SELECT COUNT(*) INTO t FROM technicians;
    SELECT COUNT(*) INTO w FROM work_orders;
    SELECT COUNT(*) INTO h FROM work_order_history;
    SELECT COUNT(*) INTO s FROM maintenance_schedules;
    RAISE NOTICE 'Seed complete: % assets, % technicians, % work orders, % schedules, % history rows.',
        a, t, w, s, h;
END $$;

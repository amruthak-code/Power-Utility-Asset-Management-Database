-- =============================================================================
-- Power Utility Asset Management — master runner
-- Run all SQL files in order against a fresh database.
--
--   createdb power_utility
--   psql -d power_utility -f run_all.sql
-- =============================================================================
\echo '== 01 schema =='
\i sql/01_schema.sql
\echo '== 02 triggers =='
\i sql/02_triggers.sql
\echo '== 03 procedures =='
\i sql/03_procedures.sql
\echo '== 04 views =='
\i sql/04_views.sql
\echo '== 05 seed data =='
\i sql/05_seed_data.sql
\echo '== Done. =='

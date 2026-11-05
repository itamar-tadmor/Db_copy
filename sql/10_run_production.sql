-- =============================================================================
-- 10_run_production.sql  -  the flow on production, one block at a time, as PCOPY.
-- Copy and run a block, review, then continue. Do NOT run this file as a whole.
-- Blocks 1-4 are read-only toward application objects. Block 6 is where production changes.
-- =============================================================================
SET SERVEROUTPUT ON LINESIZE 220 PAGESIZE 200 VERIFY OFF

-- 1. Configuration --------------------------------------------------------------
-- UPDATE pcopy_config SET param_value = '2024-11-01' WHERE param_name = 'CUTOFF_FIXED_DATE';
-- UPDATE pcopy_config SET param_value = 'Y' WHERE param_name = 'LOB_HIST_SKIP';   -- only after a positive POC
-- UPDATE pcopy_config SET param_value = '20' WHERE param_name = 'WINDOW_START_HH24';
-- UPDATE pcopy_config SET param_value = '6'  WHERE param_name = 'WINDOW_END_HH24';
-- For NUMBER/VARCHAR2 keys (see Q04 of 00_adhoc_mapping_readonly.sql):
-- INSERT INTO pcopy_table_rule (owner, table_name, key_format) VALUES ('APP','T_SALES','YYYYMMDD');
-- COMMIT;

-- 2. Mapping and checks ----------------------------------------------------------
VARIABLE run NUMBER
EXEC :run := pcopy_map.run_mapping('first analysis');
EXEC pcopy_check.run_checks(:run);
PRINT run

-- 3. Review: @11_reports.sql <run_id>. Override a recommendation when needed, then check again:
-- EXEC pcopy_map.set_ts_decision(:run, 'TS_X', 'RESTORE', 'LEAVE', 'Reason');
-- EXEC pcopy_check.run_checks(:run);

-- 4. Plan and prechecks. Nothing executes yet ------------------------------------
-- EXEC pcopy_plan.build_plan(:run);
-- EXEC pcopy_precheck.run_pre(:run);
-- Review the statements:
-- SPOOL plan.sql
-- SELECT column_value FROM TABLE(pcopy_plan.plan_script(:run));
-- SPOOL OFF

-- 5. Stop switch, from any session, at any moment --------------------------------
-- UPDATE pcopy_config SET param_value = 'Y' WHERE param_name = 'STOP_FLAG'; COMMIT;

-- 6. Execute, in small batches -----------------------------------------------------
-- Preparation: new tablespaces, quotas, opening read-only tablespaces
-- EXEC pcopy_exec.run_plan(:run, p_phase_from => 10, p_phase_to => 30);
-- Pilot: one small table
-- EXEC pcopy_exec.run_plan(:run, p_phase_from => 40, p_phase_to => 40, p_owner => 'APP', p_table => 'T_SMALL');
-- Then batches, with an archive log backup between them
-- EXEC pcopy_exec.run_plan(:run, p_phase_from => 40, p_phase_to => 40, p_max_gb => 2000);
-- Global index relocation, defaults, degree, then back to read-only
-- EXEC pcopy_exec.run_plan(:run, p_phase_from => 50, p_phase_to => 80);

-- After a failure:
-- SELECT step_id, step_type, owner, object_name, partition_name, ora_code, error_message FROM pcopy_plan_step WHERE run_id = :run AND status = 'FAILED';
-- EXEC pcopy_exec.retry_failed(:run);

-- 7. Index repair and post checks --------------------------------------------------
-- EXEC pcopy_exec.rebuild_unusable(:run, 'PLAN');
-- EXEC pcopy_precheck.run_post(:run);

-- 8. Final validation, a NEW mapping that must be clean --------------------------
-- Purge the recycle bin of skipped tablespaces first. Take the backup noted by check A05.
-- VARIABLE final NUMBER
-- EXEC :final := pcopy_map.run_mapping('final');
-- EXEC pcopy_check.run_checks(:final);
-- EXEC pcopy_check.assert_ready(:final);
-- Then rman/generate_restore_script.sql with this run id.

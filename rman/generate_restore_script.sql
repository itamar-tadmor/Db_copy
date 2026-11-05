-- =============================================================================
-- generate_restore_script.sql  -  run as PCOPY on production, against the FINAL run
-- (a mapping taken after all moves, with pcopy_check.assert_ready passing).
-- Usage: @generate_restore_script.sql <run_id> <dest> <until_scn> <channels>
--   dest example: +DATA_LOW  or  /u02/oradata/LOW/%b
--   until_scn must be above PCOPY_RUN.MAP_SCN, and covered by archive log backups.
-- Output: restore_<run_id>.rman. Review it before use.
-- =============================================================================
SET LINESIZE 300 PAGESIZE 0 FEEDBACK OFF HEADING OFF TRIMSPOOL ON VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE
EXEC pcopy_check.assert_ready(&1)
SPOOL restore_&1..rman
SELECT column_value FROM TABLE(pcopy_plan.rman_script(&1, '&2', &3, 'DEVICE TYPE DISK', &4));
SPOOL OFF

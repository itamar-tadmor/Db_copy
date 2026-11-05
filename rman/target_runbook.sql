-- =============================================================================
-- target_runbook.sql  -  ordered steps on the LOWER environment. Read before running.
-- Sections 1-3 are performed by the DBA. They are comments, not a script to run blindly.
-- =============================================================================

-- 1. INSTANCE, before anything touches the restored database
--    In the target pfile:
--      db_name = same as production until nid
--      db_unique_name = <different from production>   (PCOPY_TARGET refuses otherwise)
--      job_queue_processes = 0
--      aq_tm_processes = 0
--      log_archive_dest_n = local only. No standby destinations, no fal_server, dg_broker_start = false
--      control_files, db_create_file_dest, db_recovery_file_dest = target locations
--      sga/pga fitted to the target. cluster_database = false for a first open if the source is RAC
--    RMAN: connect WITHOUT the production recovery catalog. Do not connect to production.

-- 2. RESTORE
--    rman target /
--      STARTUP NOMOUNT;
--      RESTORE CONTROLFILE FROM '<backup piece>';   -- or from autobackup, SET DBID <dbid> first
--      ALTER DATABASE MOUNT;
--      CATALOG START WITH '<backup location>';      -- when backups were copied
--      @restore_<run_id>.rman                       -- from generate_restore_script.sql
--    Rename online logs if they do not follow the convert parameters.

-- 3. FIRST OPEN, restricted, so no application session or link activity can happen
--    STARTUP MOUNT RESTRICT is not needed if the instance was mounted above; run:
--      ALTER DATABASE OPEN RESETLOGS;
--      ALTER SYSTEM ENABLE RESTRICTED SESSION;
--    If temp files are missing:
--      ALTER TABLESPACE temp ADD TEMPFILE SIZE 100G;
--    Grant RESTRICTED SESSION to PCOPY for the cleanup.
--    Skipped files appear with status RECOVER or OFFLINE in V$DATAFILE. This is expected at this point.
--    Do not start the application yet: all HIST partitions are still in the dictionary.

SET SERVEROUTPUT ON LINESIZE 200 PAGESIZE 200 VERIFY OFF

-- 4. As SYS: production pointers and security review. Lists only. Drop or change them according to your policy.
PROMPT ===== Database links to review =====
SELECT owner, db_link, host FROM dba_db_links;
PROMPT ===== Scheduler jobs that would run when job_queue_processes is raised =====
SELECT owner, job_name, enabled, state FROM dba_scheduler_jobs WHERE enabled = 'TRUE' AND owner NOT IN ('SYS','ORACLE_OCM','DBSNMP');
PROMPT ===== External tables and directories =====
SELECT owner, directory_name, directory_path FROM dba_directories WHERE origin_con_id IS NOT NULL AND directory_name NOT LIKE 'ORACLE%' AND directory_name NOT LIKE 'DATA_PUMP%';

-- 5. As SYS: rman/target_grants.sql
-- 6. As PCOPY: dry run. Read PCOPY_LOG, statements are in SQL_TEXT.
--    EXEC pcopy_target.cleanup(p_run => <final_run>, p_work_ts => 'PCOPY_TS', p_method => 'EXCHANGE', p_dry_run => 'Y');
--    SELECT action, owner, object_name, partition_name, DBMS_LOB.SUBSTR(sql_text,300,1) stmt
--      FROM pcopy_log WHERE run_id = <final_run> AND module_name = 'PCOPY_TARGET' ORDER BY log_id;
-- 7. As PCOPY: real run
--    EXEC pcopy_target.cleanup(p_run => <final_run>, p_work_ts => 'PCOPY_TS', p_method => 'EXCHANGE', p_dry_run => 'N');
--    Errors are in PCOPY_LOG with level ERROR and in the alert log of the target: grep PCOPY-ERROR

-- 8. Verify, as SYS
PROMPT ===== No datafile should remain offline =====
SELECT f.file#, t.name ts, f.status FROM v$datafile f JOIN v$tablespace t ON t.ts# = f.ts# WHERE f.status NOT IN ('ONLINE','SYSTEM');
PROMPT ===== No unusable indexes on application schemas =====
SELECT owner, index_name, NULL part, status FROM dba_indexes WHERE status = 'UNUSABLE'
UNION ALL SELECT index_owner, index_name, partition_name, status FROM dba_ind_partitions WHERE status = 'UNUSABLE'
UNION ALL SELECT index_owner, index_name, subpartition_name, status FROM dba_ind_subpartitions WHERE status = 'UNUSABLE';
PROMPT ===== Leftover exchange tables =====
SELECT owner, table_name, tablespace_name FROM dba_tables WHERE table_name LIKE 'PCX\_%' ESCAPE '\';

-- 9. As SYS, once all above is clean:
--    @?/rdbms/admin/utlrp.sql
--    SHUTDOWN IMMEDIATE; STARTUP MOUNT;
--    host: nid TARGET=/ DBNAME=<new_name>      -- new DBID and name, separates it from the production backups
--    change db_name in the pfile, recreate the password file, STARTUP MOUNT; ALTER DATABASE OPEN RESETLOGS;
--    Take the first backup of the target with its own policy.
--    Mask sensitive data according to your policy BEFORE opening to users. It is outside this tool.
--    Refresh statistics for global indexes and tables that lost partitions.
--    Reclaim space in tablespaces that had history dropped: ALTER DATABASE DATAFILE ... RESIZE.
--    Revoke the grants from step 5 and lock PCOPY. ALTER SYSTEM DISABLE RESTRICTED SESSION, raise job_queue_processes.

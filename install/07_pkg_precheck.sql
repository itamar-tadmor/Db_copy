-- =============================================================================
-- 07_pkg_precheck.sql  -  PCOPY_PRECHECK: checks BEFORE touching production, and
--                         after the moves. Read-only toward application objects.
-- PCOPY_EXEC refuses to start without a recent precheck free of FAIL.
-- =============================================================================
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pcopy_precheck AS
  PROCEDURE run_pre(p_run NUMBER);
  PROCEDURE run_post(p_run NUMBER);
  -- Raises ORA-20130 if the last PRE batch has FAIL, or is too old.
  PROCEDURE assert_pre_ok(p_run NUMBER);
END pcopy_precheck;
/

CREATE OR REPLACE PACKAGE BODY pcopy_precheck AS

  c_mod CONSTANT VARCHAR2(30) := 'PCOPY_PRECHECK';
  g_batch NUMBER; g_run NUMBER; g_stage VARCHAR2(5);

  PROCEDURE res(p_id VARCHAR2, p_name VARCHAR2, p_status VARCHAR2, p_detail VARCHAR2) IS
  BEGIN
    INSERT INTO pcopy_precheck (run_id, batch_id, stage, check_id, check_name, status, detail)
    VALUES (g_run, g_batch, g_stage, p_id, p_name, p_status, SUBSTR(p_detail, 1, 2000));
    COMMIT;
    IF p_status = 'FAIL' THEN
      pcopy_util.write_log(g_run, 'ERROR', c_mod, p_id, p_name || ': ' || p_detail);
      pcopy_util.alert('PCOPY-ERROR run=' || g_run || ' precheck ' || p_id || ' FAILED: ' || p_name || ': ' || p_detail);
    END IF;
  END res;

  -- A check that cannot run reports WARN instead of stopping the others.
  PROCEDURE broken(p_id VARCHAR2, p_name VARCHAR2) IS
  BEGIN
    res(p_id, p_name, 'WARN', 'Check could not run: ' || SQLERRM);
  END broken;

  PROCEDURE chk_environment IS
    l_v1 VARCHAR2(200); l_v2 VARCHAR2(200); l_n NUMBER; l_d DATE;
  BEGIN
    BEGIN
      IF DBMS_DB_VERSION.VERSION > 12 OR (DBMS_DB_VERSION.VERSION = 12 AND DBMS_DB_VERSION.RELEASE >= 2) THEN
        res('P01', 'Database version', 'PASS', DBMS_DB_VERSION.VERSION || '.' || DBMS_DB_VERSION.RELEASE);
      ELSE
        res('P01', 'Database version', 'FAIL', 'ONLINE table move and FOR EXCHANGE need 12.2 or later');
      END IF;
    EXCEPTION WHEN OTHERS THEN broken('P01', 'Database version'); END;

    BEGIN
      SELECT MAX(banner) INTO l_v1 FROM v$version WHERE banner LIKE 'Oracle%';
      res('P02', 'Enterprise Edition (Partitioning, ONLINE)', CASE WHEN l_v1 LIKE '%Enterprise%' THEN 'PASS' ELSE 'FAIL' END, l_v1);
    EXCEPTION WHEN OTHERS THEN broken('P02', 'Enterprise Edition'); END;

    BEGIN
      SELECT log_mode, force_logging INTO l_v1, l_v2 FROM v$database;
      SELECT COUNT(*) INTO l_n FROM v$archive_dest WHERE status = 'VALID' AND target = 'STANDBY';
      res('P03', 'ARCHIVELOG and FORCE LOGGING',
          CASE WHEN l_v1 <> 'ARCHIVELOG' THEN 'FAIL' WHEN l_n > 0 AND l_v2 = 'NO' THEN 'FAIL' WHEN l_v2 = 'NO' THEN 'WARN' ELSE 'PASS' END,
          'log_mode=' || l_v1 || ' force_logging=' || l_v2 || ' standby_dests=' || l_n);
    EXCEPTION WHEN OTHERS THEN broken('P03', 'ARCHIVELOG and FORCE LOGGING'); END;

    BEGIN
      SELECT MAX(end_time) INTO l_d FROM v$rman_backup_job_details
      WHERE  status IN ('COMPLETED','COMPLETED WITH WARNINGS') AND input_type IN ('DB FULL','DB INCR');
      res('P04', 'Recent successful database backup',
          CASE WHEN l_d IS NULL OR l_d < SYSDATE - pcopy_util.cfg_num('MAX_BACKUP_AGE_DAYS') THEN 'FAIL' ELSE 'PASS' END,
          'Last: ' || NVL(TO_CHAR(l_d, 'YYYY-MM-DD HH24:MI'), 'none found in the controlfile'));
    EXCEPTION WHEN OTHERS THEN broken('P04', 'Recent backup'); END;

    BEGIN
      SELECT COUNT(*) INTO l_n FROM v$rman_backup_job_details WHERE status LIKE 'RUNNING%';
      res('P05', 'No RMAN backup running now', CASE WHEN l_n > 0 THEN 'WARN' ELSE 'PASS' END, l_n || ' running');
    EXCEPTION WHEN OTHERS THEN broken('P05', 'RMAN running'); END;

    BEGIN
      SELECT MAX(status) INTO l_v1 FROM v$block_change_tracking;
      res('P19', 'Block change tracking', CASE WHEN l_v1 = 'ENABLED' THEN 'PASS' ELSE 'WARN' END,
          NVL(l_v1, '?') || '. Without it, the incremental after the moves reads every block');
    EXCEPTION WHEN OTHERS THEN broken('P19', 'Block change tracking'); END;

    BEGIN
      SELECT COUNT(*) INTO l_n FROM v$restore_point WHERE guarantee_flashback_database = 'YES';
      res('P21', 'No guaranteed restore point', CASE WHEN l_n > 0 THEN 'WARN' ELSE 'PASS' END,
          l_n || ' found. Moves keep flashback logs growing: the FRA can fill');
    EXCEPTION WHEN OTHERS THEN broken('P21', 'Guaranteed restore point'); END;

    BEGIN
      SELECT COUNT(*) INTO l_n FROM v$archive_dest_status
      WHERE  status = 'ERROR' OR (type IN ('PHYSICAL','LOGICAL') AND gap_status NOT IN ('NO GAP','RESOLVABLE GAP') AND gap_status IS NOT NULL);
      res('P08', 'Archive destinations and Data Guard health', CASE WHEN l_n > 0 THEN 'FAIL' ELSE 'PASS' END, l_n || ' destinations with an error or gap');
    EXCEPTION WHEN OTHERS THEN broken('P08', 'Data Guard'); END;

    BEGIN
      SELECT MAX(value) INTO l_v1 FROM v$parameter WHERE name = 'standby_file_management';
      SELECT COUNT(*) INTO l_n FROM v$archive_dest WHERE status = 'VALID' AND target = 'STANDBY';
      res('P23', 'standby_file_management', CASE WHEN l_n > 0 AND l_v1 <> 'AUTO' THEN 'FAIL' ELSE 'PASS' END, l_v1 || ', standby destinations: ' || l_n);
    EXCEPTION WHEN OTHERS THEN broken('P23', 'standby_file_management'); END;

    BEGIN
      pcopy_util.alert('PCOPY-INFO alert log write test, run=' || g_run);
      sys.dbms_system.ksdwrt(2, 'PCOPY-INFO direct alert log write test, run=' || g_run);
      res('P20', 'Writing to the alert log', 'PASS', 'Look for PCOPY-INFO in the alert log of this instance');
    EXCEPTION WHEN OTHERS THEN res('P20', 'Writing to the alert log', 'FAIL', SQLERRM); END;
  END chk_environment;

  PROCEDURE chk_capacity(p_run NUMBER) IS
    l_total NUMBER; l_lim NUMBER; l_used NUMBER; l_free NUMBER; l_n NUMBER; l_txt VARCHAR2(2000); l_big NUMBER;
    l_factor NUMBER := pcopy_util.cfg_num('SPACE_FACTOR');
  BEGIN
    SELECT NVL(SUM(est_gb),0), NVL(MAX(CASE WHEN step_type LIKE 'REBUILD%' THEN est_gb END),0)
    INTO   l_total, l_big FROM pcopy_plan_step WHERE run_id = p_run AND status = 'PENDING' AND phase IN (40,50);

    BEGIN
      SELECT space_limit/1073741824, (space_used - space_reclaimable)/1073741824 INTO l_lim, l_used FROM v$recovery_file_dest;
      IF l_lim = 0 THEN
        res('P06', 'FRA usage', 'WARN', 'No FRA. Check the archive log destination by hand');
      ELSE
        res('P06', 'FRA usage', CASE WHEN l_used/l_lim*100 > pcopy_util.cfg_num('MAX_FRA_USED_PCT') THEN 'FAIL' ELSE 'PASS' END,
            ROUND(l_used/l_lim*100,1) || '% used of ' || ROUND(l_lim) || ' GB');
        res('P07', 'Redo volume against FRA free space', CASE WHEN l_total * 1.3 > (l_lim - l_used) THEN 'WARN' ELSE 'PASS' END,
            'Plan rewrites about ' || ROUND(l_total) || ' GB, redo about ' || ROUND(l_total*1.3) || ' GB. FRA free '
            || ROUND(l_lim - l_used) || ' GB. Split into batches with archivelog backups between them');
      END IF;
    EXCEPTION WHEN OTHERS THEN broken('P06', 'FRA usage'); END;

    -- Free space on existing targets, considering autoextend
    BEGIN
      l_txt := NULL;
      FOR r IN (SELECT p.target_ts, SUM(p.est_gb) * l_factor need_gb,
                       MAX(NVL(f.maxgb,0)) - MAX(NVL(f.allocgb,0)) + MAX(NVL(fs.freegb,0)) have_gb
                FROM   pcopy_plan_step p
                JOIN   dba_tablespaces t ON t.tablespace_name = p.target_ts
                LEFT JOIN (SELECT tablespace_name, SUM(GREATEST(bytes,maxbytes))/1073741824 maxgb, SUM(bytes)/1073741824 allocgb
                           FROM dba_data_files GROUP BY tablespace_name) f ON f.tablespace_name = p.target_ts
                LEFT JOIN (SELECT tablespace_name, SUM(bytes)/1073741824 freegb FROM dba_free_space GROUP BY tablespace_name) fs
                       ON fs.tablespace_name = p.target_ts
                WHERE  p.run_id = p_run AND p.status = 'PENDING' AND p.phase IN (40,50) AND p.source_ts <> p.target_ts
                GROUP  BY p.target_ts
                HAVING SUM(p.est_gb) * l_factor > MAX(NVL(f.maxgb,0)) - MAX(NVL(f.allocgb,0)) + MAX(NVL(fs.freegb,0))) LOOP
        l_txt := SUBSTR(l_txt || r.target_ts || ' needs ' || ROUND(r.need_gb) || ' GB, has ' || ROUND(r.have_gb) || ' GB; ', 1, 1900);
      END LOOP;
      res('P09', 'Space in existing target tablespaces', CASE WHEN l_txt IS NOT NULL THEN 'FAIL' ELSE 'PASS' END, NVL(l_txt, 'All fit'));
    EXCEPTION WHEN OTHERS THEN broken('P09', 'Target space'); END;

    -- Physical storage for the rewrite. Old segments are released only when each move ends.
    BEGIN
      SELECT NVL(SUM(usable_file_mb)/1024, -1), COUNT(*) INTO l_free, l_n FROM v$asm_diskgroup WHERE usable_file_mb > 0;
      IF l_n = 0 THEN
        res('P24', 'Disk group free space', 'WARN', 'ASM not visible. Check file system space by hand');
      ELSE
        res('P24', 'Disk group free space', CASE WHEN l_free < l_total * l_factor THEN 'WARN' ELSE 'PASS' END,
            'Usable ' || ROUND(l_free) || ' GB over all disk groups, plan rewrites ' || ROUND(l_total) || ' GB');
      END IF;
    EXCEPTION WHEN OTHERS THEN broken('P24', 'Disk group space'); END;

    BEGIN
      SELECT COUNT(*) INTO l_n FROM pcopy_plan_step WHERE run_id = p_run AND step_type = 'CREATE_TS' AND status = 'PENDING';
      SELECT MAX(value) INTO l_txt FROM v$parameter WHERE name = 'db_create_file_dest';
      res('P10', 'OMF for new tablespaces', CASE WHEN l_n > 0 AND l_txt IS NULL THEN 'FAIL' ELSE 'PASS' END,
          l_n || ' new tablespaces, db_create_file_dest=' || NVL(l_txt, 'not set'));
    EXCEPTION WHEN OTHERS THEN broken('P10', 'OMF'); END;

    -- SecureFile needs ASSM, and a target must have the source block size
    BEGIN
      SELECT COUNT(*) INTO l_n
      FROM   pcopy_segment_map s
      JOIN   dba_tablespaces t ON t.tablespace_name = s.target_ts
      JOIN   dba_lobs l ON l.owner = s.table_owner AND l.table_name = s.table_name AND l.column_name = s.lob_column
      WHERE  s.run_id = p_run AND s.role LIKE 'LOB%' AND s.target_ts IS NOT NULL
      AND    l.securefile = 'YES' AND t.segment_space_management <> 'AUTO';
      res('P11', 'SecureFile target is ASSM', CASE WHEN l_n > 0 THEN 'FAIL' ELSE 'PASS' END, l_n || ' LOB units point to a non ASSM tablespace');

      SELECT COUNT(*) INTO l_n
      FROM   pcopy_segment_map s
      JOIN   dba_tablespaces src ON src.tablespace_name = s.tablespace_name
      JOIN   dba_tablespaces tgt ON tgt.tablespace_name = s.target_ts
      WHERE  s.run_id = p_run AND s.target_ts IS NOT NULL AND src.block_size <> tgt.block_size AND s.role LIKE 'LOB%';
      res('P25', 'LOB target has the source block size', CASE WHEN l_n > 0 THEN 'FAIL' ELSE 'PASS' END, l_n || ' mismatches. LOB CHUNK depends on block size');
    EXCEPTION WHEN OTHERS THEN broken('P11', 'LOB target attributes'); END;

    BEGIN
      SELECT NVL(SUM(free_space),0)/1073741824 INTO l_free FROM dba_temp_free_space;
      res('P16', 'Temp space for the largest rebuild', CASE WHEN l_free < l_big THEN 'WARN' ELSE 'PASS' END,
          'Free temp ' || ROUND(l_free) || ' GB, largest rebuild ' || ROUND(l_big) || ' GB');
    EXCEPTION WHEN OTHERS THEN broken('P16', 'Temp space'); END;

    BEGIN
      SELECT TO_NUMBER(value) INTO l_n FROM v$parameter WHERE name = 'parallel_max_servers';
      res('P17', 'parallel_max_servers', CASE WHEN l_n < pcopy_util.cfg_num('PARALLEL_DEGREE') * 2 THEN 'WARN' ELSE 'PASS' END, TO_CHAR(l_n));
    EXCEPTION WHEN OTHERS THEN broken('P17', 'parallel_max_servers'); END;
  END chk_capacity;

  PROCEDURE chk_objects(p_run NUMBER) IS
    l_n NUMBER; l_txt VARCHAR2(2000);
  BEGIN
    BEGIN
      SELECT COUNT(*) INTO l_n FROM pcopy_violation WHERE run_id = p_run AND severity = 'CRITICAL' AND fix_type = 'MANUAL';
      res('P12', 'No unresolved CRITICAL manual violations', CASE WHEN l_n > 0 THEN 'FAIL' ELSE 'PASS' END, l_n || ' violations');
      SELECT COUNT(*) INTO l_n FROM pcopy_plan_step WHERE run_id = p_run AND status = 'MANUAL';
      res('P26', 'Manual steps in the plan', CASE WHEN l_n > 0 THEN 'WARN' ELSE 'PASS' END, l_n || ' steps');
    EXCEPTION WHEN OTHERS THEN broken('P12', 'Violations'); END;

    BEGIN
      SELECT COUNT(DISTINCT o.owner || '.' || o.object_name), SUBSTR(LISTAGG(DISTINCT o.owner || '.' || o.object_name, ', ' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY o.owner || '.' || o.object_name), 1, 1500)
      INTO   l_n, l_txt
      FROM   gv$locked_object lo
      JOIN   dba_objects o ON o.object_id = lo.object_id
      JOIN   pcopy_plan_step p ON p.run_id = p_run AND p.owner = o.owner AND p.object_name = o.object_name AND p.status = 'PENDING';
      res('P13', 'Plan tables locked right now', CASE WHEN l_n > 0 THEN 'WARN' ELSE 'PASS' END, l_n || ' tables. ' || l_txt);
    EXCEPTION WHEN OTHERS THEN broken('P13', 'Locks'); END;

    BEGIN
      SELECT COUNT(*) INTO l_n FROM gv$transaction
      WHERE  TO_DATE(start_time, 'MM/DD/YY HH24:MI:SS') < SYSDATE - 4/24;
      res('P22', 'Long transactions (over 4 hours)', CASE WHEN l_n > 0 THEN 'WARN' ELSE 'PASS' END,
          l_n || '. ALTER TABLESPACE READ ONLY waits for them');
    EXCEPTION WHEN OTHERS THEN broken('P22', 'Long transactions'); END;

    -- Is the "history" really cold?
    BEGIN
      BEGIN DBMS_STATS.flush_database_monitoring_info; EXCEPTION WHEN OTHERS THEN NULL; END;
      SELECT COUNT(*), SUBSTR(LISTAGG(owner || '.' || object_name || ':' || partition_name, ', ' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY 1), 1, 1500)
      INTO   l_n, l_txt
      FROM (SELECT DISTINCT p.owner, p.object_name, p.partition_name
            FROM   pcopy_plan_step p
            JOIN   dba_tab_modifications m ON m.table_owner = p.owner AND m.table_name = p.object_name
                   AND (m.partition_name = p.partition_name OR m.subpartition_name = p.partition_name)
            WHERE  p.run_id = p_run AND p.data_class = 'HIST' AND p.step_type IN ('MOVE_PART','MOVE_SUBPART')
            AND    m.inserts + m.updates + m.deletes > pcopy_util.cfg_num('HOT_HIST_DML_ROWS'));
      res('P14', 'History partitions are cold', CASE WHEN l_n > 0 THEN 'WARN' ELSE 'PASS' END,
          l_n || ' HIST partitions with recent DML. COLD move locks them: consider HOT. ' || l_txt);
    EXCEPTION WHEN OTHERS THEN broken('P14', 'Cold history'); END;

    BEGIN
      SELECT COUNT(*) INTO l_n FROM dba_scheduler_running_jobs;
      res('P18', 'Scheduler jobs running now', CASE WHEN l_n > 0 THEN 'WARN' ELSE 'PASS' END, l_n || ' running. Check stats and ETL windows');
    EXCEPTION WHEN OTHERS THEN broken('P18', 'Scheduler'); END;
  END chk_objects;

  PROCEDURE take_baseline(p_run NUMBER) IS
    l_u NUMBER; l_i NUMBER; l_done NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_done FROM pcopy_plan_step WHERE run_id = p_run AND status IN ('DONE','RUNNING','FAILED');
    IF l_done > 0 THEN RETURN; END IF;     -- baseline is only valid before the first change
    DELETE FROM pcopy_baseline WHERE run_id = p_run;
    INSERT INTO pcopy_baseline (run_id, kind, owner, object_name, status)
    SELECT p_run, 'UNUSABLE_INDEX', owner, index_name, status FROM dba_indexes WHERE status = 'UNUSABLE';
    INSERT INTO pcopy_baseline (run_id, kind, owner, object_name, partition_name, status)
    SELECT p_run, 'UNUSABLE_INDEX', index_owner, index_name, partition_name, status FROM dba_ind_partitions WHERE status = 'UNUSABLE';
    INSERT INTO pcopy_baseline (run_id, kind, owner, object_name, partition_name, status)
    SELECT p_run, 'UNUSABLE_INDEX', index_owner, index_name, subpartition_name, status FROM dba_ind_subpartitions WHERE status = 'UNUSABLE';
    SELECT COUNT(*) INTO l_u FROM pcopy_baseline WHERE run_id = p_run AND kind = 'UNUSABLE_INDEX';
    INSERT INTO pcopy_baseline (run_id, kind, owner, object_name, status)
    SELECT p_run, 'INVALID_OBJECT', owner, object_name || ':' || object_type, status FROM dba_objects WHERE status = 'INVALID';
    l_i := SQL%ROWCOUNT;
    COMMIT;
    res('P15', 'Baseline taken', 'PASS', l_u || ' unusable indexes or partitions, ' || l_i
        || ' invalid objects existed before the process. They will not be rebuilt or blamed on it');
  END take_baseline;

  PROCEDURE start_batch(p_run NUMBER, p_stage VARCHAR2) IS
  BEGIN
    g_run := p_run; g_stage := p_stage;
    SELECT NVL(MAX(batch_id),0) + 1 INTO g_batch FROM pcopy_precheck WHERE run_id = p_run;
  END start_batch;

  PROCEDURE run_pre(p_run NUMBER) IS
    l_f NUMBER; l_w NUMBER;
  BEGIN
    start_batch(p_run, 'PRE');
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'START', 'Prechecks, batch ' || g_batch);
    chk_environment;
    chk_capacity(p_run);
    chk_objects(p_run);
    take_baseline(p_run);
    SELECT COUNT(CASE WHEN status='FAIL' THEN 1 END), COUNT(CASE WHEN status='WARN' THEN 1 END)
    INTO   l_f, l_w FROM pcopy_precheck WHERE run_id = p_run AND batch_id = g_batch;
    pcopy_util.write_log(p_run, CASE WHEN l_f > 0 THEN 'ERROR' WHEN l_w > 0 THEN 'WARN' ELSE 'INFO' END, c_mod, 'END', 'FAIL=' || l_f || ' WARN=' || l_w);
  END run_pre;

  PROCEDURE assert_pre_ok(p_run NUMBER) IS
    l_batch NUMBER; l_at TIMESTAMP; l_f NUMBER;
  BEGIN
    SELECT MAX(batch_id) INTO l_batch FROM pcopy_precheck WHERE run_id = p_run AND stage = 'PRE';
    IF l_batch IS NULL THEN
      RAISE_APPLICATION_ERROR(-20130, 'No precheck for run ' || p_run);
    END IF;
    SELECT MAX(checked_at), COUNT(CASE WHEN status='FAIL' THEN 1 END) INTO l_at, l_f
    FROM   pcopy_precheck WHERE run_id = p_run AND batch_id = l_batch;
    IF l_f > 0 THEN
      RAISE_APPLICATION_ERROR(-20130, 'Last precheck has ' || l_f || ' FAIL results');
    END IF;
    IF CAST(l_at AS DATE) < SYSDATE - pcopy_util.cfg_num('PRECHECK_MAX_AGE_HOURS')/24 THEN
      RAISE_APPLICATION_ERROR(-20130, 'Last precheck is too old. Run pcopy_precheck.run_pre again');
    END IF;
  END assert_pre_ok;

  PROCEDURE run_post(p_run NUMBER) IS
    l_n NUMBER; l_txt VARCHAR2(2000);
  BEGIN
    start_batch(p_run, 'POST');
    SELECT COUNT(*) INTO l_n FROM pcopy_plan_step WHERE run_id = p_run AND status NOT IN ('DONE','SKIPPED');
    res('A01', 'All steps finished', CASE WHEN l_n > 0 THEN 'FAIL' ELSE 'PASS' END, l_n || ' steps PENDING, RUNNING, FAILED or MANUAL');

    SELECT COUNT(*) INTO l_n FROM (
      SELECT owner, index_name, CAST(NULL AS VARCHAR2(128)) part FROM dba_indexes WHERE status = 'UNUSABLE'
      UNION ALL SELECT index_owner, index_name, partition_name FROM dba_ind_partitions WHERE status = 'UNUSABLE'
      UNION ALL SELECT index_owner, index_name, subpartition_name FROM dba_ind_subpartitions WHERE status = 'UNUSABLE') u
    WHERE NOT EXISTS (SELECT 1 FROM pcopy_baseline b WHERE b.run_id = p_run AND b.kind = 'UNUSABLE_INDEX'
                      AND b.owner = u.owner AND b.object_name = u.index_name AND NVL(b.partition_name,'~') = NVL(u.part,'~'));
    res('A02', 'No new unusable indexes', CASE WHEN l_n > 0 THEN 'FAIL' ELSE 'PASS' END, l_n || ' new. Run pcopy_exec.rebuild_unusable');

    SELECT COUNT(*) INTO l_n FROM dba_objects o WHERE o.status = 'INVALID'
    AND NOT EXISTS (SELECT 1 FROM pcopy_baseline b WHERE b.run_id = p_run AND b.kind = 'INVALID_OBJECT'
                    AND b.owner = o.owner AND b.object_name = o.object_name || ':' || o.object_type);
    res('A03', 'No new invalid objects', CASE WHEN l_n > 0 THEN 'WARN' ELSE 'PASS' END, l_n || ' new');

    SELECT COUNT(*) INTO l_n FROM pcopy_plan_step s
    WHERE  s.run_id = p_run AND s.step_type = 'TS_RO'
    AND    EXISTS (SELECT 1 FROM dba_tablespaces t WHERE t.tablespace_name = s.object_name AND t.status <> 'READ ONLY');
    res('A04', 'History tablespaces are read-only again', CASE WHEN l_n > 0 THEN 'FAIL' ELSE 'PASS' END, l_n || ' not read-only');

    -- Every tablespace rewritten needs a backup that the restore can use.
    SELECT SUBSTR(LISTAGG(DISTINCT ts, ',' ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY ts), 1, 1900) INTO l_txt
    FROM (SELECT target_ts ts FROM pcopy_plan_step WHERE run_id = p_run AND phase IN (40,50)
          UNION SELECT source_ts FROM pcopy_plan_step WHERE run_id = p_run AND phase IN (40,50));
    res('A05', 'New backup after the moves', 'WARN', 'Take a new backup including: ' || l_txt
        || '. Then run a NEW mapping and pcopy_check.assert_ready on it');
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'POST', 'Post checks, batch ' || g_batch);
  END run_post;

END pcopy_precheck;
/
SHOW ERRORS

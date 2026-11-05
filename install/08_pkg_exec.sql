-- =============================================================================
-- 08_pkg_exec.sql  -  PCOPY_EXEC: runs the plan one step at a time.
-- - each step: status + log row before and after, redo and elapsed recorded
-- - each failure: PCOPY_LOG row, PCOPY_PLAN_STEP row, and a line in the alert log
-- - restartable: DONE steps are not repeated, retry_failed returns FAILED to PENDING
-- - batches: run from several sessions with different p_owner / p_table filters
-- =============================================================================
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pcopy_exec AS
  PROCEDURE run_plan(p_run NUMBER, p_phase_from NUMBER DEFAULT 0, p_phase_to NUMBER DEFAULT 999,
                     p_owner VARCHAR2 DEFAULT NULL, p_table VARCHAR2 DEFAULT NULL,
                     p_max_gb NUMBER DEFAULT NULL, p_max_steps NUMBER DEFAULT NULL);
  -- Rebuilds every index or partition that is UNUSABLE and was not so at baseline.
  -- p_scope: PLAN = only tables in this plan. ALL = whole database (used on the target).
  PROCEDURE rebuild_unusable(p_run NUMBER, p_scope VARCHAR2 DEFAULT 'PLAN', p_online VARCHAR2 DEFAULT 'Y');
  PROCEDURE retry_failed(p_run NUMBER);
  -- Marks a MANUAL step as done, after the DBA executed it by hand.
  PROCEDURE mark_manual_done(p_step NUMBER, p_note VARCHAR2);
END pcopy_exec;
/

CREATE OR REPLACE PACKAGE BODY pcopy_exec AS

  c_mod CONSTANT VARCHAR2(30) := 'PCOPY_EXEC';
  e_busy EXCEPTION; PRAGMA EXCEPTION_INIT(e_busy, -54);

  FUNCTION my_redo_mb RETURN NUMBER IS
    l NUMBER;
  BEGIN
    SELECT m.value/1048576 INTO l FROM v$mystat m JOIN v$statname n ON n.statistic# = m.statistic# WHERE n.name = 'redo size';
    RETURN l;
  EXCEPTION WHEN OTHERS THEN RETURN NULL;
  END my_redo_mb;

  PROCEDURE setup_session IS
  BEGIN
    EXECUTE IMMEDIATE 'ALTER SESSION SET ddl_lock_timeout = ' || pcopy_util.cfg_num('DDL_LOCK_TIMEOUT');
    EXECUTE IMMEDIATE 'ALTER SESSION ENABLE RESUMABLE TIMEOUT ' || pcopy_util.cfg_num('RESUMABLE_TIMEOUT') || ' NAME ''PCOPY''';
    EXECUTE IMMEDIATE 'ALTER SESSION ENABLE PARALLEL DDL';
    DBMS_APPLICATION_INFO.set_module('PCOPY', 'run_plan');
  END setup_session;

  -- Returns the reason to stop now, or NULL.
  FUNCTION runtime_stop_reason RETURN VARCHAR2 IS
    l_lim NUMBER; l_used NUMBER; l_n NUMBER;
    l_s VARCHAR2(10) := pcopy_util.cfg('WINDOW_START_HH24');
    l_e VARCHAR2(10) := pcopy_util.cfg('WINDOW_END_HH24');
    l_h NUMBER := TO_NUMBER(TO_CHAR(SYSDATE, 'HH24'));
    l_lag VARCHAR2(40); l_sec NUMBER;
  BEGIN
    IF pcopy_util.cfg('STOP_FLAG') = 'Y' THEN RETURN 'STOP_FLAG is set'; END IF;

    IF l_s IS NOT NULL AND l_e IS NOT NULL THEN
      IF (TO_NUMBER(l_s) <= TO_NUMBER(l_e) AND NOT (l_h >= TO_NUMBER(l_s) AND l_h < TO_NUMBER(l_e)))
      OR (TO_NUMBER(l_s) >  TO_NUMBER(l_e) AND NOT (l_h >= TO_NUMBER(l_s) OR  l_h < TO_NUMBER(l_e))) THEN
        RETURN 'Outside the work window ' || l_s || '-' || l_e;
      END IF;
    END IF;

    BEGIN
      SELECT space_limit, space_used - space_reclaimable INTO l_lim, l_used FROM v$recovery_file_dest;
      IF l_lim > 0 AND l_used/l_lim*100 > pcopy_util.cfg_num('MAX_FRA_USED_PCT') THEN
        RETURN 'FRA ' || ROUND(l_used/l_lim*100,1) || '% used';
      END IF;
    EXCEPTION WHEN NO_DATA_FOUND THEN NULL;
    END;

    SELECT COUNT(*) INTO l_n FROM v$archive_dest_status WHERE status = 'ERROR';
    IF l_n > 0 THEN RETURN l_n || ' archive destinations in ERROR'; END IF;

    -- Standby lag, when this database shows it
    FOR r IN (SELECT name, value FROM v$dataguard_stats WHERE name IN ('apply lag','transport lag') AND value IS NOT NULL) LOOP
      l_lag := r.value;  -- +DD HH:MI:SS
      BEGIN
        l_sec := EXTRACT(DAY FROM TO_DSINTERVAL(l_lag))*86400 + EXTRACT(HOUR FROM TO_DSINTERVAL(l_lag))*3600
               + EXTRACT(MINUTE FROM TO_DSINTERVAL(l_lag))*60 + EXTRACT(SECOND FROM TO_DSINTERVAL(l_lag));
        IF l_sec > pcopy_util.cfg_num('MAX_APPLY_LAG_SEC') THEN
          RETURN 'Data Guard ' || r.name || ' is ' || l_lag;
        END IF;
      EXCEPTION WHEN OTHERS THEN NULL;   -- an unreadable lag value must not stop the run
      END;
    END LOOP;
    RETURN NULL;
  END runtime_stop_reason;

  -- A RESTORE_DEGREE step that nothing changed is not run: ALTER TABLE invalidates cursors.
  FUNCTION degree_unchanged(s pcopy_plan_step%ROWTYPE) RETURN BOOLEAN IS
    l_d VARCHAR2(40);
  BEGIN
    IF s.step_type <> 'RESTORE_DEGREE' THEN RETURN FALSE; END IF;
    BEGIN
      SELECT TRIM(degree) INTO l_d FROM dba_tables WHERE owner = s.owner AND table_name = s.object_name;
    EXCEPTION WHEN NO_DATA_FOUND THEN
      SELECT TRIM(degree) INTO l_d FROM dba_indexes WHERE owner = s.owner AND index_name = s.object_name;
    END;
    RETURN l_d = s.expected_value;
  END degree_unchanged;

  -- Dictionary confirmation that the object really is where the step said.
  PROCEDURE verify_location(s pcopy_plan_step%ROWTYPE) IS
    l_ts VARCHAR2(30);
  BEGIN
    IF s.step_type = 'MOVE_PART' THEN
      SELECT tablespace_name INTO l_ts FROM dba_tab_partitions
      WHERE table_owner = s.owner AND table_name = s.object_name AND partition_name = s.partition_name;
    ELSIF s.step_type = 'MOVE_SUBPART' THEN
      SELECT tablespace_name INTO l_ts FROM dba_tab_subpartitions
      WHERE table_owner = s.owner AND table_name = s.object_name AND subpartition_name = s.partition_name;
    ELSIF s.step_type = 'MOVE_TABLE' THEN
      SELECT tablespace_name INTO l_ts FROM dba_tables WHERE owner = s.owner AND table_name = s.object_name;
    ELSIF s.step_type IN ('REBUILD_LOCAL','REBUILD_GLOBAL') AND s.partition_name IS NULL THEN
      SELECT tablespace_name INTO l_ts FROM dba_indexes WHERE owner = s.owner AND index_name = s.object_name;
    ELSIF s.step_type IN ('REBUILD_LOCAL','REBUILD_GLOBAL') THEN
      SELECT MAX(tablespace_name) INTO l_ts FROM (
        SELECT tablespace_name FROM dba_ind_partitions WHERE index_owner = s.owner AND index_name = s.object_name AND partition_name = s.partition_name
        UNION ALL
        SELECT tablespace_name FROM dba_ind_subpartitions WHERE index_owner = s.owner AND index_name = s.object_name AND subpartition_name = s.partition_name);
    ELSE
      RETURN;
    END IF;
    IF NVL(l_ts,'~') <> NVL(s.target_ts,'~') THEN
      RAISE_APPLICATION_ERROR(-20140, 'Verification failed: object is in ' || l_ts || ', expected ' || s.target_ts);
    END IF;
  END verify_location;

  PROCEDURE finish(p_step NUMBER, p_status VARCHAR2, p_redo0 NUMBER, p_code NUMBER DEFAULT NULL, p_err VARCHAR2 DEFAULT NULL, p_note VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_redo NUMBER := my_redo_mb;
  BEGIN
    UPDATE pcopy_plan_step
    SET    status = p_status, ended_at = SYSTIMESTAMP,
           elapsed_sec = (CAST(SYSTIMESTAMP AS DATE) - CAST(started_at AS DATE)) * 86400,
           redo_mb = CASE WHEN p_redo0 IS NOT NULL AND l_redo IS NOT NULL THEN ROUND(l_redo - p_redo0, 1) END,
           ora_code = p_code, error_message = SUBSTR(p_err, 1, 4000), note = NVL(p_note, note)
    WHERE  step_id = p_step;
    COMMIT;
  END finish;

  -- Returns TRUE on success.
  FUNCTION run_step(s pcopy_plan_step%ROWTYPE) RETURN BOOLEAN IS
    l_redo0 NUMBER := my_redo_mb;
    l_tries NUMBER := pcopy_util.cfg_num('LOCK_RETRIES');
    l_try   NUMBER := 0;
  BEGIN
    DBMS_APPLICATION_INFO.set_action('step ' || s.step_id);
    pcopy_util.write_log(s.run_id, 'INFO', c_mod, s.step_type || ' START', 'est_gb=' || ROUND(s.est_gb,2) || ' mode=' || s.move_mode,
                         s.step_id, s.owner, s.object_name, s.partition_name, s.target_ts, s.sql_text);
    IF degree_unchanged(s) THEN
      finish(s.step_id, 'SKIPPED', l_redo0, p_note => 'Degree unchanged');
      RETURN TRUE;
    END IF;
    LOOP
      BEGIN
        EXECUTE IMMEDIATE s.sql_text;
        EXIT;
      EXCEPTION WHEN e_busy THEN
        l_try := l_try + 1;
        IF l_try > l_tries THEN RAISE; END IF;
        pcopy_util.write_log(s.run_id, 'WARN', c_mod, s.step_type || ' BUSY', 'ORA-00054, retry ' || l_try || ' of ' || l_tries, s.step_id, s.owner, s.object_name, s.partition_name);
        DBMS_SESSION.sleep(LEAST(60 * l_try, 300));
      END;
    END LOOP;
    verify_location(s);
    finish(s.step_id, 'DONE', l_redo0);
    pcopy_util.write_log(s.run_id, 'INFO', c_mod, s.step_type || ' DONE', 'Completed', s.step_id, s.owner, s.object_name, s.partition_name, s.target_ts);
    RETURN TRUE;
  EXCEPTION WHEN OTHERS THEN
    DECLARE
      l_code NUMBER := SQLCODE; l_errm VARCHAR2(4000) := SQLERRM;
    BEGIN
      pcopy_util.log_error(s.run_id, c_mod, s.step_type, NULL, s.step_id, s.owner, s.object_name, s.partition_name, s.target_ts, s.sql_text, l_code, l_errm);
      finish(s.step_id, 'FAILED', l_redo0, l_code, l_errm);
    END;
    RETURN FALSE;
  END run_step;

  PROCEDURE run_plan(p_run NUMBER, p_phase_from NUMBER DEFAULT 0, p_phase_to NUMBER DEFAULT 999,
                     p_owner VARCHAR2 DEFAULT NULL, p_table VARCHAR2 DEFAULT NULL,
                     p_max_gb NUMBER DEFAULT NULL, p_max_steps NUMBER DEFAULT NULL) IS
    s        pcopy_plan_step%ROWTYPE;
    l_reason VARCHAR2(400);
    l_gb     NUMBER := 0; l_steps NUMBER := 0; l_failed NUMBER := 0; l_dep VARCHAR2(10); l_ok BOOLEAN;
    l_stop_on_error BOOLEAN := pcopy_util.cfg('STOP_ON_ERROR') = 'Y';
  BEGIN
    pcopy_precheck.assert_pre_ok(p_run);
    setup_session;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'RUN START', 'phases ' || p_phase_from || '-' || p_phase_to
                         || ' owner=' || p_owner || ' table=' || p_table || ' max_gb=' || p_max_gb);
    pcopy_util.alert('PCOPY-INFO run=' || p_run || ' execution started, phases ' || p_phase_from || '-' || p_phase_to);

    LOOP
      -- Pick the next step, and claim it safely against parallel sessions
      BEGIN
        SELECT * INTO s FROM (
          SELECT * FROM pcopy_plan_step
          WHERE  run_id = p_run AND status = 'PENDING' AND phase BETWEEN p_phase_from AND p_phase_to
          AND    (p_owner IS NULL OR owner = p_owner)
          AND    (p_table IS NULL OR object_name = p_table)
          ORDER  BY phase, seq)
        WHERE ROWNUM = 1;
      EXCEPTION WHEN NO_DATA_FOUND THEN EXIT;
      END;

      IF p_max_gb IS NOT NULL AND l_gb + s.est_gb > p_max_gb AND l_steps > 0 THEN
        l_reason := 'Batch limit of ' || p_max_gb || ' GB reached'; EXIT;
      END IF;
      IF p_max_steps IS NOT NULL AND l_steps >= p_max_steps THEN
        l_reason := 'Batch limit of ' || p_max_steps || ' steps reached'; EXIT;
      END IF;
      l_reason := runtime_stop_reason;
      IF l_reason IS NOT NULL THEN
        pcopy_util.write_log(p_run, 'WARN', c_mod, 'RUN STOP', l_reason);
        pcopy_util.alert('PCOPY-WARN run=' || p_run || ' execution stopped: ' || l_reason);
        EXIT;
      END IF;

      -- A rebuild whose move did not succeed must not run
      IF s.dep_step_id IS NOT NULL THEN
        SELECT status INTO l_dep FROM pcopy_plan_step WHERE step_id = s.dep_step_id;
        IF l_dep <> 'DONE' THEN
          UPDATE pcopy_plan_step SET status = 'SKIPPED', note = 'Depends on step ' || s.dep_step_id || ', status ' || l_dep
          WHERE  step_id = s.step_id;
          COMMIT;
          pcopy_util.write_log(p_run, 'WARN', c_mod, s.step_type || ' SKIPPED', 'Dependency in status ' || l_dep, s.step_id, s.owner, s.object_name, s.partition_name);
          CONTINUE;
        END IF;
      END IF;

      UPDATE pcopy_plan_step SET status = 'RUNNING', started_at = SYSTIMESTAMP, attempts = attempts + 1
      WHERE  step_id = s.step_id AND status = 'PENDING';
      IF SQL%ROWCOUNT = 0 THEN
        COMMIT; CONTINUE;      -- another session took it
      END IF;
      COMMIT;

      l_ok := run_step(s);
      l_steps := l_steps + 1;
      l_gb := l_gb + s.est_gb;
      IF NOT l_ok THEN
        l_failed := l_failed + 1;
        IF l_stop_on_error THEN
          l_reason := 'STOP_ON_ERROR: step ' || s.step_id || ' failed';
          EXIT;
        END IF;
      END IF;
    END LOOP;

    pcopy_util.write_log(p_run, CASE WHEN l_failed > 0 THEN 'ERROR' ELSE 'INFO' END, c_mod, 'RUN END',
        l_steps || ' steps, ' || ROUND(l_gb) || ' GB, ' || l_failed || ' failed. ' || l_reason);
    pcopy_util.alert('PCOPY-' || CASE WHEN l_failed > 0 THEN 'ERROR' ELSE 'INFO' END || ' run=' || p_run
                     || ' execution ended: ' || l_steps || ' steps, ' || l_failed || ' failed. ' || l_reason);
    EXECUTE IMMEDIATE 'ALTER SESSION DISABLE RESUMABLE';
  EXCEPTION WHEN OTHERS THEN
    pcopy_util.log_error(p_run, c_mod, 'RUN_PLAN');
    RAISE;
  END run_plan;

  PROCEDURE rebuild_unusable(p_run NUMBER, p_scope VARCHAR2 DEFAULT 'PLAN', p_online VARCHAR2 DEFAULT 'Y') IS
    l_par  NUMBER := pcopy_util.cfg_num('PARALLEL_DEGREE');
    l_sql  VARCHAR2(1000); l_ok NUMBER := 0; l_bad NUMBER := 0; l_deg VARCHAR2(40);
    l_prev VARCHAR2(300);
    PROCEDURE reset_degree(p_o VARCHAR2, p_i VARCHAR2) IS
      l_d VARCHAR2(40) := NVL(l_deg, '1');
    BEGIN
      -- Rebuild with PARALLEL persists the degree on the index: put back what it had before.
      EXECUTE IMMEDIATE 'ALTER INDEX ' || pcopy_util.q(p_o) || '.' || pcopy_util.q(p_i) || ' '
        || CASE WHEN l_d = '1' THEN 'NOPARALLEL' WHEN l_d = 'DEFAULT' THEN 'PARALLEL' ELSE 'PARALLEL ' || l_d END;
    EXCEPTION WHEN OTHERS THEN
      pcopy_util.log_error(p_run, c_mod, 'RESET_DEGREE', NULL, NULL, p_o, p_i);
    END reset_degree;
  BEGIN
    setup_session;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'REBUILD_UNUSABLE START', 'scope=' || p_scope);
    FOR r IN (
      SELECT u.owner, u.index_name, u.lvl, u.part
      FROM (
        SELECT i.owner, i.index_name, 'INDEX' lvl, CAST(NULL AS VARCHAR2(128)) part, i.table_owner, i.table_name
        FROM   dba_indexes i WHERE i.status = 'UNUSABLE' AND i.index_type NOT IN ('LOB','DOMAIN')
        UNION ALL
        SELECT ip.index_owner, ip.index_name, 'PARTITION', ip.partition_name, i.table_owner, i.table_name
        FROM   dba_ind_partitions ip JOIN dba_indexes i ON i.owner = ip.index_owner AND i.index_name = ip.index_name
        WHERE  ip.status = 'UNUSABLE' AND i.index_type NOT IN ('LOB','DOMAIN')
        UNION ALL
        SELECT sp.index_owner, sp.index_name, 'SUBPARTITION', sp.subpartition_name, i.table_owner, i.table_name
        FROM   dba_ind_subpartitions sp JOIN dba_indexes i ON i.owner = sp.index_owner AND i.index_name = sp.index_name
        WHERE  sp.status = 'UNUSABLE' AND i.index_type NOT IN ('LOB','DOMAIN')
      ) u
      -- run_id <= p_run: the final mapping has no baseline of its own, the first precheck's one applies
      WHERE NOT EXISTS (SELECT 1 FROM pcopy_baseline b WHERE b.run_id <= p_run AND b.kind = 'UNUSABLE_INDEX'
                        AND b.owner = u.owner AND b.object_name = u.index_name AND NVL(b.partition_name,'~') = NVL(u.part,'~'))
      AND (p_scope = 'ALL'
           OR EXISTS (SELECT 1 FROM pcopy_plan_step p WHERE p.run_id = p_run AND p.step_type LIKE 'MOVE%'
                      AND p.owner = u.table_owner AND p.object_name = u.table_name))
      ORDER BY u.owner, u.index_name, u.part
    ) LOOP
      IF l_prev IS NULL OR l_prev <> r.owner || '.' || r.index_name THEN
        IF l_prev IS NOT NULL THEN
          reset_degree(SUBSTR(l_prev, 1, INSTR(l_prev,'.')-1), SUBSTR(l_prev, INSTR(l_prev,'.')+1));
        END IF;
        SELECT TRIM(degree) INTO l_deg FROM dba_indexes WHERE owner = r.owner AND index_name = r.index_name;
      END IF;
      l_prev := r.owner || '.' || r.index_name;
      l_sql := 'ALTER INDEX ' || pcopy_util.q(r.owner) || '.' || pcopy_util.q(r.index_name) || ' REBUILD'
            || CASE r.lvl WHEN 'PARTITION' THEN ' PARTITION ' || pcopy_util.q(r.part)
                          WHEN 'SUBPARTITION' THEN ' SUBPARTITION ' || pcopy_util.q(r.part) END
            || ' PARALLEL ' || l_par || CASE WHEN p_online = 'Y' THEN ' ONLINE' END;
      BEGIN
        pcopy_util.write_log(p_run, 'INFO', c_mod, 'REBUILD START', r.lvl, NULL, r.owner, r.index_name, r.part, NULL, l_sql);
        EXECUTE IMMEDIATE l_sql;
        l_ok := l_ok + 1;
      EXCEPTION WHEN OTHERS THEN
        l_bad := l_bad + 1;
        pcopy_util.log_error(p_run, c_mod, 'REBUILD_UNUSABLE', NULL, NULL, r.owner, r.index_name, r.part, NULL, l_sql);
      END;
    END LOOP;
    IF l_prev IS NOT NULL THEN
      reset_degree(SUBSTR(l_prev, 1, INSTR(l_prev,'.')-1), SUBSTR(l_prev, INSTR(l_prev,'.')+1));
    END IF;
    pcopy_util.write_log(p_run, CASE WHEN l_bad > 0 THEN 'ERROR' ELSE 'INFO' END, c_mod, 'REBUILD_UNUSABLE END', l_ok || ' rebuilt, ' || l_bad || ' failed');
  END rebuild_unusable;

  PROCEDURE retry_failed(p_run NUMBER) IS
  BEGIN
    UPDATE pcopy_plan_step SET status = 'PENDING', ora_code = NULL, error_message = NULL
    WHERE  run_id = p_run AND status = 'FAILED';
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'RETRY_FAILED', SQL%ROWCOUNT || ' steps returned to PENDING');
    UPDATE pcopy_plan_step SET status = 'PENDING', note = NULL
    WHERE  run_id = p_run AND status = 'SKIPPED' AND dep_step_id IS NOT NULL;
    COMMIT;
  END retry_failed;

  PROCEDURE mark_manual_done(p_step NUMBER, p_note VARCHAR2) IS
    l_run NUMBER;
  BEGIN
    UPDATE pcopy_plan_step SET status = 'DONE', ended_at = SYSTIMESTAMP, note = 'BY HAND: ' || p_note
    WHERE  step_id = p_step AND status = 'MANUAL'
    RETURNING run_id INTO l_run;
    IF l_run IS NULL THEN RAISE_APPLICATION_ERROR(-20141, 'Step is not MANUAL: ' || p_step); END IF;
    COMMIT;
    pcopy_util.write_log(l_run, 'WARN', c_mod, 'MANUAL DONE', p_note, p_step);
  END mark_manual_done;

END pcopy_exec;
/
SHOW ERRORS

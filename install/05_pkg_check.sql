-- =============================================================================
-- 05_pkg_check.sql  -  PCOPY_CHECK: self-containment rules against the decided
--                      skip list. Read-only toward application objects.
-- Run after pcopy_map.run_mapping and after any override.
-- Run again on a NEW mapping after the moves: the skip list is only trusted when
-- assert_ready passes on the final run.
--
-- Definition used here. A partitioned table that spans restored and skipped
-- tablespaces is NOT self-contained for DBMS_TTS (expected, reported once and
-- ignored). The set is usable when:
--   R1  nothing that must exist on the target lives in a skipped tablespace
--   R2  everything in a skipped tablespace belongs to a HIST partition
--   R3  all segments of one HIST partition are on the same side
-- =============================================================================
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pcopy_check AS
  PROCEDURE run_checks(p_run NUMBER);
  -- Raises ORA-20110 when CRITICAL or HIGH violations remain.
  PROCEDURE assert_ready(p_run NUMBER);
END pcopy_check;
/

CREATE OR REPLACE PACKAGE BODY pcopy_check AS

  c_mod CONSTANT VARCHAR2(30) := 'PCOPY_CHECK';

  PROCEDURE add_v(p_run NUMBER, p_rule VARCHAR2, p_sev VARCHAR2, p_fix VARCHAR2, p_owner VARCHAR2, p_obj VARCHAR2,
                  p_part VARCHAR2, p_ts VARCHAR2, p_gb NUMBER, p_detail VARCHAR2) IS
  BEGIN
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, partition_name, tablespace_name, gb, detail)
    VALUES (p_run, p_rule, p_sev, p_fix, p_owner, p_obj, p_part, p_ts, p_gb, SUBSTR(p_detail, 1, 1000));
  END add_v;

  PROCEDURE rules_containment(p_run NUMBER) IS
  BEGIN
    -- V01 recent data or full tables inside a skipped tablespace
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, partition_name, tablespace_name, gb, detail)
    SELECT p_run, 'V01', 'CRITICAL', 'PLAN', s.table_owner, s.table_name, NVL(s.table_subpartition, s.table_partition), s.tablespace_name, s.gb,
           s.role || ' ' || s.seg_name || ' must exist on target but is in a skipped tablespace'
    FROM   pcopy_segment_map s
    JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name AND t.decision = 'SKIP'
    WHERE  s.run_id = p_run AND s.data_class = 'KEEP' AND s.role NOT IN ('OTHER','LOBINDEX');

    -- V02 objects the automation cannot move: SYS objects, IOT, nested, clusters, domain secondary objects
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, partition_name, tablespace_name, gb, detail)
    SELECT p_run, 'V02', 'CRITICAL', 'MANUAL', s.seg_owner, s.seg_name, s.seg_partition, s.tablespace_name, s.gb,
           'Segment type ' || s.segment_type || ' in a skipped tablespace. Handle manually or change the decision to RESTORE'
    FROM   pcopy_segment_map s
    JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name AND t.decision = 'SKIP'
    WHERE  s.run_id = p_run AND s.role = 'OTHER';

    -- V03 a HIST partition split across restored and skipped tablespaces
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, partition_name, tablespace_name, gb, detail)
    SELECT p_run, 'V03', 'WARN', 'PLAN', s.table_owner, s.table_name, s.table_partition, MIN(s.tablespace_name), SUM(s.gb),
           'HIST partition spans skipped and restored tablespaces: '
           || LISTAGG(DISTINCT s.role || '@' || s.tablespace_name, ', ') WITHIN GROUP (ORDER BY s.role || '@' || s.tablespace_name)
    FROM   pcopy_segment_map s
    JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name
    WHERE  s.run_id = p_run AND s.data_class = 'HIST' AND s.role <> 'LOBINDEX'
    GROUP  BY s.table_owner, s.table_name, s.table_partition
    HAVING COUNT(CASE WHEN t.decision = 'SKIP' THEN 1 END) > 0
    AND    COUNT(CASE WHEN t.decision <> 'SKIP' THEN 1 END) > 0;

    -- V04 default attributes pointing at a skipped tablespace: new partitions would land there
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, tablespace_name, detail)
    SELECT p_run, 'V04', 'HIGH', 'PLAN', pt.owner, pt.table_name, pt.def_tablespace_name, 'Table default tablespace is skipped'
    FROM   dba_part_tables pt
    JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = pt.def_tablespace_name AND t.decision = 'SKIP';
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, tablespace_name, detail)
    SELECT p_run, 'V04', 'HIGH', 'PLAN', pi.owner, pi.index_name, pi.def_tablespace_name, 'Index default tablespace is skipped'
    FROM   dba_part_indexes pi
    JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = pi.def_tablespace_name AND t.decision = 'SKIP';
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, tablespace_name, detail)
    SELECT p_run, 'V04', 'HIGH', 'PLAN', pl.table_owner, pl.table_name, pl.def_tablespace_name,
           'LOB default tablespace is skipped, column ' || pl.column_name
    FROM   dba_part_lobs pl
    JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = pl.def_tablespace_name AND t.decision = 'SKIP';

    -- V05 subpartition template pointing at a skipped tablespace
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, tablespace_name, detail)
    SELECT p_run, 'V05', 'HIGH', 'MANUAL', st.user_name, st.table_name, st.tablespace_name,
           'Subpartition template ' || st.subpartition_name || ' uses a skipped tablespace: SET SUBPARTITION TEMPLATE'
    FROM   dba_subpartition_templates st
    JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = st.tablespace_name AND t.decision = 'SKIP';

    -- V08 materialized view container or MV log in a skipped tablespace
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, tablespace_name, gb, detail)
    SELECT p_run, 'V08', 'CRITICAL', 'MANUAL', s.seg_owner, s.seg_name, s.tablespace_name, s.gb,
           'Materialized view container or log in a skipped tablespace. RMAN refuses to skip these'
    FROM   pcopy_segment_map s
    JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name AND t.decision = 'SKIP'
    WHERE  s.run_id = p_run
    AND   (EXISTS (SELECT 1 FROM dba_mviews mv WHERE mv.owner = s.seg_owner AND mv.container_name = s.seg_name)
           OR EXISTS (SELECT 1 FROM dba_mview_logs ml WHERE ml.log_owner = s.seg_owner AND ml.log_table = s.seg_name));

    -- V09 LONG columns cannot be moved
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, tablespace_name, gb, detail)
    SELECT p_run, 'V09', 'CRITICAL', 'MANUAL', s.table_owner, s.table_name, s.tablespace_name, s.gb,
           'LONG column in a table in a skipped tablespace. ALTER TABLE MOVE is not possible: convert to LOB or use Data Pump'
    FROM   pcopy_segment_map s
    JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name AND t.decision = 'SKIP'
    WHERE  s.run_id = p_run AND s.role = 'TABLE'
    AND    EXISTS (SELECT 1 FROM dba_tab_cols c WHERE c.owner = s.table_owner AND c.table_name = s.table_name
                   AND c.data_type IN ('LONG','LONG RAW'));

    -- V14 a user's default tablespace is skipped
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, tablespace_name, detail)
    SELECT p_run, 'V14', 'HIGH', 'MANUAL', u.username, u.default_tablespace, 'User default tablespace is skipped: ALTER USER DEFAULT TABLESPACE'
    FROM   dba_users u
    JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = u.default_tablespace AND t.decision = 'SKIP';

    -- V13 recycle bin in a skipped tablespace
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, tablespace_name, detail)
    SELECT p_run, 'V13', 'INFO', 'MANUAL', r.owner, r.object_name, r.ts_name, 'Recycle bin object, ' || r.original_name || ': PURGE before the final mapping'
    FROM   dba_recyclebin r
    JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = r.ts_name AND t.decision = 'SKIP';
    COMMIT;
  END rules_containment;

  PROCEDURE rules_target_impact(p_run NUMBER) IS
  BEGIN
    -- V06 global indexes on tables losing partitions
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, tablespace_name, gb, detail)
    SELECT p_run, 'V06', 'WARN', 'TARGET', s.seg_owner, s.seg_name, MIN(s.tablespace_name), SUM(s.gb),
           'Global index on ' || s.table_owner || '.' || s.table_name || ': restored at full size with history keys, rebuilt on target'
    FROM   pcopy_segment_map s
    WHERE  s.run_id = p_run AND s.is_global = 'Y'
    AND    EXISTS (SELECT 1 FROM pcopy_partition_map m WHERE m.run_id = p_run AND m.table_owner = s.table_owner
                   AND m.table_name = s.table_name AND m.data_class = 'HIST')
    GROUP  BY s.seg_owner, s.seg_name, s.table_owner, s.table_name;

    -- V07 foreign keys into tables losing partitions
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, detail)
    SELECT p_run, 'V07', 'WARN', 'TARGET', c.owner, c.table_name,
           'FK ' || c.constraint_name || ' references ' || p.owner || '.' || p.table_name
           || ', which loses partitions. Child rows may be orphaned: FK re-enabled NOVALIDATE on target'
    FROM   dba_constraints c
    JOIN   dba_constraints p ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
    WHERE  c.constraint_type = 'R'
    AND    EXISTS (SELECT 1 FROM pcopy_partition_map m WHERE m.run_id = p_run AND m.table_owner = p.owner
                   AND m.table_name = p.table_name AND m.data_class = 'HIST');

    -- V10 tables kept in full only because the key could not be evaluated
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, gb, detail)
    SELECT p_run, 'V10', 'WARN', 'MANUAL', m.table_owner, m.table_name,
           (SELECT SUM(s.gb) FROM pcopy_segment_map s WHERE s.run_id = p_run AND s.table_owner = m.table_owner AND s.table_name = m.table_name),
           'Kept in full, reason ' || MIN(m.class_reason) || '. Add PCOPY_TABLE_RULE if it holds history'
    FROM   pcopy_partition_map m
    WHERE  m.run_id = p_run
    AND   (m.class_reason IN ('NON_DATE_KEY_NO_RULE','BOUND_NOT_PARSEABLE','MULTI_COLUMN_KEY')
           OR m.class_reason LIKE 'NOT_RANGE%')
    GROUP  BY m.table_owner, m.table_name;

    -- V11 all-history tables keeping their newest partition
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, partition_name, detail)
    SELECT p_run, 'V11', 'INFO', 'NONE', m.table_owner, m.table_name, m.partition_name,
           'All partitions are history. The newest is kept, because a table cannot lose its last partition'
    FROM   pcopy_partition_map m WHERE m.run_id = p_run AND m.class_reason = 'LAST_PARTITION_PRESERVED';

    -- V15 HCC: the restored blocks can only be read on storage that supports HCC
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, detail)
    SELECT p_run, 'V15', 'WARN', 'MANUAL', x.owner, x.table_name,
           'HCC data (' || x.compress_for || '): the target must be on HCC capable storage, otherwise ORA-64307'
    FROM (SELECT table_owner owner, table_name, MIN(compress_for) compress_for FROM dba_tab_partitions
          WHERE compress_for LIKE 'QUERY%' OR compress_for LIKE 'ARCHIVE%' GROUP BY table_owner, table_name
          UNION
          SELECT table_owner, table_name, MIN(compress_for) FROM dba_tab_subpartitions
          WHERE compress_for LIKE 'QUERY%' OR compress_for LIKE 'ARCHIVE%' GROUP BY table_owner, table_name
          UNION
          SELECT owner, table_name, compress_for FROM dba_tables
          WHERE compress_for LIKE 'QUERY%' OR compress_for LIKE 'ARCHIVE%') x;

    -- V16 encrypted tablespaces on the restore list
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, tablespace_name, detail)
    SELECT p_run, 'V16', 'INFO', 'MANUAL', t.tablespace_name, 'TDE encrypted: the source wallet/keystore must be available on the target'
    FROM   pcopy_ts_map t WHERE t.run_id = p_run AND t.encrypted = 'YES' AND t.decision <> 'SKIP';

    -- V17 ONLINE move restrictions on recent data that needs to move
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, tablespace_name, detail)
    SELECT DISTINCT p_run, 'V17', 'HIGH', 'MANUAL', s.table_owner, s.table_name, s.tablespace_name,
           'Recent data must move, but ONLINE is not allowed (domain/bitmap join index, object type or IOT): plan an outage'
    FROM   pcopy_segment_map s
    JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name AND t.decision = 'SKIP'
    WHERE  s.run_id = p_run AND s.data_class = 'KEEP' AND s.role NOT IN ('OTHER','LOBINDEX')
    AND   (EXISTS (SELECT 1 FROM dba_indexes i WHERE i.table_owner = s.table_owner AND i.table_name = s.table_name
                   AND (i.index_type = 'DOMAIN' OR i.join_index = 'YES'))
           OR EXISTS (SELECT 1 FROM dba_object_tables o WHERE o.owner = s.table_owner AND o.table_name = s.table_name)
           OR EXISTS (SELECT 1 FROM dba_tab_cols c WHERE c.owner = s.table_owner AND c.table_name = s.table_name
                      AND c.data_type_owner IS NOT NULL AND c.data_type_owner NOT IN ('SYS','PUBLIC')));

    -- V18 read-only tablespaces holding recent partitions
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, partition_name, tablespace_name, gb, detail)
    SELECT p_run, 'V18', 'WARN', 'NONE', s.table_owner, s.table_name, s.table_partition, s.tablespace_name, s.gb,
           'Partition newer than the cutoff in a read-only tablespace'
    FROM   pcopy_segment_map s
    JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name AND t.status = 'READ ONLY'
    WHERE  s.run_id = p_run AND s.data_class = 'KEEP' AND s.role IN ('TABLE_PART','TABLE_SUB');

    -- V19 storage restored only because cleanup needs it online
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, tablespace_name, gb, detail)
    SELECT p_run, 'V19', 'INFO', 'NONE', t.tablespace_name, t.complex_hist_gb,
           'History restored temporarily (LOB, reference...), space is released on target. '
           || 'A positive POC for LOB allows LOB_HIST_SKIP=Y'
    FROM   pcopy_ts_map t WHERE t.run_id = p_run AND t.complex_hist_gb > 0;
    COMMIT;
  END rules_target_impact;

  -- LOB specific rules
  PROCEDURE rules_lob(p_run NUMBER) IS
    l_warn NUMBER := pcopy_util.cfg_num('BASICFILE_WARN_GB');
  BEGIN
    -- L01 LOB that must exist on target, in a skipped tablespace
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, partition_name, tablespace_name, gb, detail)
    SELECT p_run, 'L01', 'CRITICAL', 'PLAN', s.table_owner, s.table_name, s.table_partition, s.tablespace_name, s.gb,
           'LOB column ' || s.lob_column || ' (recent or full table) in a skipped tablespace. MOVE needs an explicit LOB clause'
    FROM   pcopy_segment_map s
    JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name AND t.decision = 'SKIP'
    WHERE  s.run_id = p_run AND s.data_class = 'KEEP' AND s.role IN ('LOB','LOB_PART','LOB_SUB');

    -- L02 LOB in a different tablespace than its table partition, across the skip boundary
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, partition_name, tablespace_name, gb, detail)
    SELECT p_run, 'L02', 'HIGH', 'PLAN', tb.table_owner, tb.table_name, NVL(tb.table_subpartition, tb.table_partition), lb.tablespace_name, lb.gb,
           'Column ' || lb.lob_column || ': table in ' || tb.tablespace_name || ' (' || tt.decision || '), LOB in '
           || lb.tablespace_name || ' (' || lt.decision || ')'
    FROM   pcopy_segment_map tb
    JOIN   pcopy_segment_map lb ON lb.run_id = tb.run_id AND lb.table_owner = tb.table_owner AND lb.table_name = tb.table_name
                               AND lb.table_partition = tb.table_partition
                               AND NVL(lb.table_subpartition,'~') = NVL(tb.table_subpartition,'~')
                               AND lb.role IN ('LOB_PART','LOB_SUB')
    JOIN   pcopy_ts_map tt ON tt.run_id = tb.run_id AND tt.tablespace_name = tb.tablespace_name
    JOIN   pcopy_ts_map lt ON lt.run_id = lb.run_id AND lt.tablespace_name = lb.tablespace_name
    WHERE  tb.run_id = p_run AND tb.role IN ('TABLE_PART','TABLE_SUB')
    AND    CASE WHEN tt.decision = 'SKIP' THEN 1 ELSE 0 END <> CASE WHEN lt.decision = 'SKIP' THEN 1 ELSE 0 END;

    -- L03 large BasicFile LOB: moves slowly, is not parallel
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, gb, detail)
    SELECT p_run, 'L03', 'WARN', 'NONE', l.owner, l.table_name, SUM(s.gb),
           'BasicFile column ' || l.column_name || ': serial and slow to move, plan separate windows'
    FROM   dba_lobs l
    JOIN   pcopy_segment_map s ON s.run_id = p_run AND s.table_owner = l.owner AND s.table_name = l.table_name
                              AND s.lob_column = l.column_name AND s.role IN ('LOB','LOB_PART','LOB_SUB')
    WHERE  l.securefile = 'NO'
    GROUP  BY l.owner, l.table_name, l.column_name
    HAVING SUM(s.gb) >= l_warn;

    -- L04 SecureFile with compression, deduplication or encryption: options and target wallet
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, detail)
    SELECT p_run, 'L04', 'INFO', 'NONE', l.owner, l.table_name,
           'Column ' || l.column_name || ': compression=' || l.compression || ', dedup=' || l.deduplication || ', encrypt=' || l.encrypt
           || '. MOVE keeps these. Needs the licensed option, and the wallet for encrypted LOBs'
    FROM   dba_lobs l
    JOIN   dba_users u ON u.username = l.owner AND u.oracle_maintained = 'N'
    WHERE  l.securefile = 'YES'
    AND    (l.compression NOT IN ('NONE','NO') OR l.deduplication NOT IN ('NONE','NO') OR l.encrypt NOT IN ('NONE','NO'));

    -- L06 LOB that cannot be named in a simple LOB clause: XMLType, object attribute, hidden column
    INSERT INTO pcopy_violation (run_id, rule_id, severity, fix_type, owner, object_name, tablespace_name, gb, detail)
    SELECT p_run, 'L06', 'HIGH', 'MANUAL', s.table_owner, s.table_name, s.tablespace_name, SUM(s.gb),
           'Column ' || SUBSTR(s.lob_column,1,200) || ' is XMLType, object attribute or hidden. The plan marks its move MANUAL'
    FROM   pcopy_segment_map s
    JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name AND t.action IN ('MOVE_KEEP_OUT','MOVE_HIST_OUT')
    WHERE  s.run_id = p_run AND s.role IN ('LOB','LOB_PART','LOB_SUB')
    AND    NOT EXISTS (SELECT 1 FROM dba_tab_cols c WHERE c.owner = s.table_owner AND c.table_name = s.table_name
                       AND c.column_name = s.lob_column AND c.hidden_column = 'NO' AND c.data_type IN ('CLOB','BLOB','NCLOB'))
    GROUP  BY s.table_owner, s.table_name, s.tablespace_name, s.lob_column;
    COMMIT;
  END rules_lob;

  -- Oracle's own check on the skip set. "Partially contained" partitioned tables are expected by design.
  PROCEDURE rule_tts(p_run NUMBER) IS
    l_list CLOB; l_expected PLS_INTEGER := 0;
  BEGIN
    FOR r IN (SELECT tablespace_name FROM pcopy_ts_map WHERE run_id = p_run AND decision = 'SKIP') LOOP
      l_list := CASE WHEN l_list IS NOT NULL THEN l_list || ',' END || r.tablespace_name;
    END LOOP;
    IF l_list IS NULL THEN
      pcopy_util.write_log(p_run, 'INFO', c_mod, 'DBMS_TTS', 'Skip list is empty');
      RETURN;
    END IF;

    sys.dbms_tts.transport_set_check(ts_list => l_list, incl_constraints => TRUE, full_check => TRUE);

    FOR v IN (SELECT violations FROM sys.transport_set_violations) LOOP
      IF LOWER(v.violations) LIKE '%partially contained%' OR v.violations LIKE 'ORA-39901%' THEN
        l_expected := l_expected + 1;
      ELSE
        add_v(p_run, 'V12', 'HIGH', 'MANUAL', NULL, NULL, NULL, NULL, NULL, 'DBMS_TTS: ' || v.violations);
      END IF;
    END LOOP;
    COMMIT;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'DBMS_TTS', l_expected
       || ' expected "partially contained" messages ignored. DUPLICATE ... SKIP TABLESPACE would refuse this set: use the partial restore');
  EXCEPTION WHEN OTHERS THEN
    pcopy_util.log_error(p_run, c_mod, 'DBMS_TTS', 'DBMS_TTS check failed');
    add_v(p_run, 'V12', 'HIGH', 'MANUAL', NULL, NULL, NULL, NULL, NULL, 'DBMS_TTS could not run: ' || SQLERRM);
    COMMIT;
  END rule_tts;

  PROCEDURE run_checks(p_run NUMBER) IS
    l_crit NUMBER; l_high NUMBER;
  BEGIN
    DELETE FROM pcopy_violation WHERE run_id = p_run;
    COMMIT;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'START', 'Containment checks started');
    rules_containment(p_run);
    rules_lob(p_run);
    rules_target_impact(p_run);
    rule_tts(p_run);
    SELECT COUNT(CASE WHEN severity = 'CRITICAL' THEN 1 END), COUNT(CASE WHEN severity = 'HIGH' THEN 1 END)
    INTO   l_crit, l_high FROM pcopy_violation WHERE run_id = p_run;
    pcopy_util.write_log(p_run, CASE WHEN l_crit + l_high > 0 THEN 'WARN' ELSE 'INFO' END, c_mod, 'END',
                         'CRITICAL=' || l_crit || ' HIGH=' || l_high);
  EXCEPTION WHEN OTHERS THEN
    pcopy_util.log_error(p_run, c_mod, 'RUN_CHECKS');
    ROLLBACK;
    RAISE;
  END run_checks;

  PROCEDURE assert_ready(p_run NUMBER) IS
    l_n NUMBER; l_skip NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM pcopy_violation WHERE run_id = p_run AND severity IN ('CRITICAL','HIGH');
    SELECT COUNT(*) INTO l_skip FROM pcopy_ts_map WHERE run_id = p_run AND decision = 'SKIP';
    IF l_n > 0 THEN
      RAISE_APPLICATION_ERROR(-20110, 'Run ' || p_run || ' is NOT ready: ' || l_n || ' CRITICAL/HIGH violations remain');
    END IF;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'ASSERT_READY', 'Ready. ' || l_skip || ' tablespaces on the skip list');
  END assert_ready;

END pcopy_check;
/
SHOW ERRORS

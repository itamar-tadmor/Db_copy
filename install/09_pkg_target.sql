-- =============================================================================
-- 09_pkg_target.sql  -  PCOPY_TARGET: cleanup on the LOWER environment after the
--                       partial restore. Compiled everywhere, runs only on the target.
--
-- Guards: DB_UNIQUE_NAME differs from production, the database passed a RESETLOGS
-- after the mapping SCN, and the target privileges exist (rman/target_grants.sql).
-- Default is dry run: statements are logged, nothing is executed.
--
-- HIST partition in an ONLINE tablespace:  DROP PARTITION.
-- HIST partition in a skipped (offline) tablespace, p_method:
--   EXCHANGE: exchange it with an empty table EXCLUDING INDEXES WITHOUT VALIDATION, drop the
--             now empty partition. The exchange table holds the offline segment and goes
--             away with DROP TABLESPACE ... INCLUDING CONTENTS.
--   DIRECT:   DROP PARTITION as is. Fails with ORA-14117 if the table has any index.
-- The POC (poc/poc_offline_cleanup.sql) decides which one holds on your version.
-- =============================================================================
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pcopy_target AS
  PROCEDURE check_target(p_run NUMBER);
  PROCEDURE cleanup(p_run NUMBER, p_work_ts VARCHAR2, p_method VARCHAR2 DEFAULT 'EXCHANGE', p_dry_run VARCHAR2 DEFAULT 'Y');
END pcopy_target;
/

CREATE OR REPLACE PACKAGE BODY pcopy_target AS

  c_mod CONSTANT VARCHAR2(30) := 'PCOPY_TARGET';
  g_run NUMBER; g_dry BOOLEAN; g_err NUMBER := 0; g_cx NUMBER := 0;

  TYPE t_str IS TABLE OF VARCHAR2(1000);
  TYPE t_map IS TABLE OF VARCHAR2(1000) INDEX BY VARCHAR2(300);

  FUNCTION q(p VARCHAR2) RETURN VARCHAR2 IS BEGIN RETURN pcopy_util.q(p); END q;

  FUNCTION do_ddl(p_sql VARCHAR2, p_action VARCHAR2, p_owner VARCHAR2 DEFAULT NULL, p_obj VARCHAR2 DEFAULT NULL, p_part VARCHAR2 DEFAULT NULL) RETURN BOOLEAN IS
  BEGIN
    pcopy_util.write_log(g_run, 'INFO', c_mod, p_action || CASE WHEN g_dry THEN ' DRYRUN' END, 'DDL', NULL, p_owner, p_obj, p_part, NULL, p_sql);
    IF NOT g_dry THEN
      EXECUTE IMMEDIATE p_sql;
    END IF;
    RETURN TRUE;
  EXCEPTION WHEN OTHERS THEN
    g_err := g_err + 1;
    pcopy_util.log_error(g_run, c_mod, p_action, NULL, NULL, p_owner, p_obj, p_part, NULL, p_sql);
    RETURN FALSE;
  END do_ddl;

  FUNCTION ts_offline(p_ts VARCHAR2) RETURN BOOLEAN IS
    l_n NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_n FROM v$datafile f JOIN v$tablespace t ON t.ts# = f.ts#
    WHERE  t.name = p_ts AND f.status NOT IN ('ONLINE','SYSTEM');
    RETURN l_n > 0;
  END ts_offline;

  PROCEDURE check_target(p_run NUMBER) IS
    l_uniq VARCHAR2(30); l_rl NUMBER; l_map NUMBER; l_bad NUMBER; l_role VARCHAR2(20);
  BEGIN
    SELECT db_unique_name, resetlogs_change#, database_role INTO l_uniq, l_rl, l_role FROM v$database;
    SELECT map_scn INTO l_map FROM pcopy_run WHERE run_id = p_run;

    IF l_uniq = pcopy_util.cfg('PROD_DB_UNIQUE_NAME') THEN
      RAISE_APPLICATION_ERROR(-20150, 'This database has the production DB_UNIQUE_NAME. Refusing to run');
    END IF;
    IF l_map IS NULL OR l_rl <= l_map THEN
      RAISE_APPLICATION_ERROR(-20151, 'RESETLOGS SCN ' || l_rl || ' is not above mapping SCN ' || l_map
        || '. Either this is not a restored copy, or it was recovered to before the final mapping');
    END IF;
    IF l_role <> 'PRIMARY' THEN
      RAISE_APPLICATION_ERROR(-20152, 'Unexpected database role ' || l_role);
    END IF;

    -- Must-have objects inside a skipped tablespace: data on target would be missing.
    SELECT COUNT(*) INTO l_bad FROM (
      SELECT tp.table_owner, tp.table_name FROM dba_tab_partitions tp
      JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = tp.tablespace_name AND t.decision = 'SKIP'
      LEFT JOIN pcopy_partition_map m ON m.run_id = p_run AND m.table_owner = tp.table_owner AND m.table_name = tp.table_name AND m.partition_name = tp.partition_name
      WHERE  NVL(m.data_class,'KEEP') <> 'HIST'
      UNION ALL
      SELECT ts.table_owner, ts.table_name FROM dba_tab_subpartitions ts
      JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = ts.tablespace_name AND t.decision = 'SKIP'
      LEFT JOIN pcopy_partition_map m ON m.run_id = p_run AND m.table_owner = ts.table_owner AND m.table_name = ts.table_name AND m.partition_name = ts.partition_name
      WHERE  NVL(m.data_class,'KEEP') <> 'HIST'
      UNION ALL
      SELECT tb.owner, tb.table_name FROM dba_tables tb
      JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = tb.tablespace_name AND t.decision = 'SKIP'
      WHERE  tb.table_name NOT LIKE 'PCX\_%' ESCAPE '\'
      UNION ALL
      SELECT lp.table_owner, lp.table_name FROM dba_lob_partitions lp
      JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = lp.tablespace_name AND t.decision = 'SKIP'
      LEFT JOIN pcopy_partition_map m ON m.run_id = p_run AND m.table_owner = lp.table_owner AND m.table_name = lp.table_name AND m.partition_name = lp.partition_name
      WHERE  NVL(m.data_class,'KEEP') <> 'HIST');
    IF l_bad > 0 THEN
      RAISE_APPLICATION_ERROR(-20153, l_bad || ' objects that must exist are inside skipped tablespaces. '
        || 'The restore does not match this run: check DDL between the mapping and the UNTIL SCN');
    END IF;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'CHECK_TARGET', 'Guards passed on ' || l_uniq);
  END check_target;

  -- Offline partition: exchange segment(s) away, leaving an empty partition in an online tablespace.
  FUNCTION exchange_out(p_o VARCHAR2, p_t VARCHAR2, p_part VARCHAR2, p_sub VARCHAR2, p_work_ts VARCHAR2) RETURN BOOLEAN IS
    l_cx VARCHAR2(128);
  BEGIN
    g_cx := g_cx + 1;
    l_cx := 'PCX_' || g_run || '_' || g_cx;
    IF NOT do_ddl('CREATE TABLE ' || q(p_o) || '.' || q(l_cx) || ' TABLESPACE ' || q(p_work_ts)
                  || ' FOR EXCHANGE WITH TABLE ' || q(p_o) || '.' || q(p_t),
                  'CREATE_EXCHANGE_TABLE', p_o, l_cx) THEN
      RETURN FALSE;
    END IF;
    RETURN do_ddl('ALTER TABLE ' || q(p_o) || '.' || q(p_t) || ' EXCHANGE '
                  || CASE WHEN p_sub IS NOT NULL THEN 'SUBPARTITION ' || q(p_sub) ELSE 'PARTITION ' || q(p_part) END
                  || ' WITH TABLE ' || q(p_o) || '.' || q(l_cx) || ' EXCLUDING INDEXES WITHOUT VALIDATION',
                  'EXCHANGE_OUT', p_o, p_t, NVL(p_sub, p_part));
  END exchange_out;

  PROCEDURE cleanup(p_run NUMBER, p_work_ts VARCHAR2, p_method VARCHAR2 DEFAULT 'EXCHANGE', p_dry_run VARCHAR2 DEFAULT 'Y') IS
    l_intervals t_map; l_fks t_str := t_str(); l_key VARCHAR2(300); l_ok BOOLEAN; l_off BOOLEAN;
    l_tot NUMBER := 0; l_drop NUMBER := 0; l_failed NUMBER := 0; l_n NUMBER; l_o VARCHAR2(128); l_t VARCHAR2(128);
  BEGIN
    g_run := p_run; g_dry := (p_dry_run <> 'N'); g_err := 0; g_cx := 0;
    IF p_method NOT IN ('EXCHANGE','DIRECT') THEN
      RAISE_APPLICATION_ERROR(-20154, 'Invalid p_method');
    END IF;
    check_target(p_run);
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'CLEANUP START', 'method=' || p_method || ' dry_run=' || p_dry_run);

    -- 1. Disable FKs pointing to tables that lose partitions
    FOR r IN (SELECT c.owner, c.table_name, c.constraint_name
              FROM   dba_constraints c
              JOIN   dba_constraints p ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
              WHERE  c.constraint_type = 'R' AND c.status = 'ENABLED'
              AND    EXISTS (SELECT 1 FROM pcopy_partition_map m WHERE m.run_id = p_run AND m.table_owner = p.owner
                             AND m.table_name = p.table_name AND m.data_class = 'HIST' AND m.partitioning_type <> 'REFERENCE')
              AND    NOT EXISTS (SELECT 1 FROM dba_part_tables x WHERE x.owner = c.owner AND x.ref_ptn_constraint_name = c.constraint_name)) LOOP
      IF do_ddl('ALTER TABLE ' || q(r.owner) || '.' || q(r.table_name) || ' DISABLE CONSTRAINT ' || q(r.constraint_name),
                'DISABLE_FK', r.owner, r.table_name) THEN
        l_fks.EXTEND;
        l_fks(l_fks.COUNT) := 'ALTER TABLE ' || q(r.owner) || '.' || q(r.table_name) || ' ENABLE NOVALIDATE CONSTRAINT ' || q(r.constraint_name);
      END IF;
    END LOOP;

    -- 2. Interval tables: the last range partition cannot be dropped (ORA-14758). Convert, restore later.
    FOR r IN (SELECT DISTINCT m.table_owner, m.table_name, pt.interval
              FROM   pcopy_partition_map m
              JOIN   dba_part_tables pt ON pt.owner = m.table_owner AND pt.table_name = m.table_name
              WHERE  m.run_id = p_run AND m.data_class = 'HIST' AND pt.interval IS NOT NULL) LOOP
      IF do_ddl('ALTER TABLE ' || q(r.table_owner) || '.' || q(r.table_name) || ' SET INTERVAL ()', 'INTERVAL_OFF', r.table_owner, r.table_name) THEN
        l_intervals(r.table_owner || '.' || r.table_name) := r.interval;
      END IF;
    END LOOP;

    -- 3. Remove HIST partitions. Reference children go with their parent.
    FOR r IN (SELECT m.table_owner, m.table_name, m.partition_name, m.is_composite, tp.tablespace_name
              FROM   pcopy_partition_map m
              JOIN   dba_tab_partitions tp ON tp.table_owner = m.table_owner AND tp.table_name = m.table_name AND tp.partition_name = m.partition_name
              WHERE  m.run_id = p_run AND m.data_class = 'HIST' AND m.partitioning_type <> 'REFERENCE'
              ORDER  BY m.table_owner, m.table_name, m.partition_position) LOOP
      l_tot := l_tot + 1;
      l_ok := TRUE;
      IF r.is_composite = 'YES' THEN
        SELECT COUNT(*) INTO l_n FROM dba_tab_subpartitions ts
        JOIN   v$tablespace vt ON vt.name = ts.tablespace_name
        JOIN   v$datafile f ON f.ts# = vt.ts#
        WHERE  ts.table_owner = r.table_owner AND ts.table_name = r.table_name AND ts.partition_name = r.partition_name
        AND    f.status NOT IN ('ONLINE','SYSTEM');
        l_off := l_n > 0;
      ELSE
        l_off := ts_offline(r.tablespace_name);
      END IF;

      IF l_off AND p_method = 'EXCHANGE' THEN
        IF r.is_composite = 'YES' THEN
          FOR s IN (SELECT subpartition_name FROM dba_tab_subpartitions
                    WHERE table_owner = r.table_owner AND table_name = r.table_name AND partition_name = r.partition_name
                    ORDER BY subpartition_position) LOOP
            l_ok := l_ok AND exchange_out(r.table_owner, r.table_name, r.partition_name, s.subpartition_name, p_work_ts);
          END LOOP;
        ELSE
          l_ok := exchange_out(r.table_owner, r.table_name, r.partition_name, NULL, p_work_ts);
        END IF;
      END IF;

      IF l_ok THEN
        l_ok := do_ddl('ALTER TABLE ' || q(r.table_owner) || '.' || q(r.table_name) || ' DROP PARTITION ' || q(r.partition_name),
                       'DROP_PARTITION', r.table_owner, r.table_name, r.partition_name);
      END IF;
      IF l_ok THEN l_drop := l_drop + 1; ELSE l_failed := l_failed + 1; END IF;
    END LOOP;
    pcopy_util.write_log(p_run, CASE WHEN l_failed > 0 THEN 'ERROR' ELSE 'INFO' END, c_mod, 'PARTITIONS',
                         l_drop || ' of ' || l_tot || ' removed, ' || l_failed || ' failed');

    -- 4. Interval back on
    l_key := l_intervals.FIRST;
    WHILE l_key IS NOT NULL LOOP
      l_o := SUBSTR(l_key, 1, INSTR(l_key,'.')-1); l_t := SUBSTR(l_key, INSTR(l_key,'.')+1);
      l_ok := do_ddl('ALTER TABLE ' || q(l_o) || '.' || q(l_t) || ' SET INTERVAL (' || l_intervals(l_key) || ')', 'INTERVAL_ON', l_o, l_t);
      l_key := l_intervals.NEXT(l_key);
    END LOOP;

    -- 5. Drop the skipped tablespaces. Only clean ones: an earlier failure would raise ORA-14404 here anyway.
    FOR r IN (SELECT tablespace_name, decision FROM pcopy_ts_map WHERE run_id = p_run AND decision IN ('SKIP','RESTORE_DROP')) LOOP
      IF r.decision = 'RESTORE_DROP' AND NOT g_dry THEN
        SELECT COUNT(*) INTO l_n FROM dba_segments WHERE tablespace_name = r.tablespace_name;
        IF l_n > 0 THEN
          pcopy_util.write_log(p_run, 'WARN', c_mod, 'KEEP_TS', 'Still has ' || l_n || ' segments, stays', p_ts => r.tablespace_name);
          CONTINUE;
        END IF;
      END IF;
      l_ok := do_ddl('DROP TABLESPACE ' || q(r.tablespace_name) || ' INCLUDING CONTENTS AND DATAFILES CASCADE CONSTRAINTS',
                     'DROP_TABLESPACE', NULL, r.tablespace_name);
    END LOOP;

    -- 6. Rebuild global indexes and any local partition left unusable
    IF NOT g_dry THEN
      pcopy_exec.rebuild_unusable(p_run, 'ALL', 'N');
    END IF;

    -- 7. FKs back, without validating: child rows of removed history stay orphaned on purpose
    FOR i IN 1 .. l_fks.COUNT LOOP
      l_ok := do_ddl(l_fks(i), 'ENABLE_FK_NOVALIDATE');
    END LOOP;

    pcopy_util.write_log(p_run, CASE WHEN g_err > 0 THEN 'ERROR' ELSE 'INFO' END, c_mod, 'CLEANUP END', g_err || ' errors');
    IF g_err > 0 THEN
      pcopy_util.alert('PCOPY-ERROR run=' || p_run || ' target cleanup ended with ' || g_err || ' errors. See PCOPY_LOG');
    END IF;
  EXCEPTION WHEN OTHERS THEN
    pcopy_util.log_error(p_run, c_mod, 'CLEANUP');
    RAISE;
  END cleanup;

END pcopy_target;
/
SHOW ERRORS

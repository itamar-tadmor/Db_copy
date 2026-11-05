-- =============================================================================
-- 06_pkg_plan.sql  -  PCOPY_PLAN: turns decisions into reviewed, ordered steps.
-- Builds PCOPY_PLAN_STEP only. Executes nothing.
--
-- Index strategy:
--  COLD (history)  ALTER TABLE MOVE [UPDATE GLOBAL INDEXES], local index partition becomes
--                  UNUSABLE for that partition only, then REBUILD into the target tablespace.
--  HOT  (recent)   ALTER TABLE MOVE ... UPDATE INDEXES ... ONLINE: all indexes stay usable, DML
--                  continues. Then REBUILD ONLINE only to relocate local index partitions.
-- =============================================================================
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pcopy_plan AS
  TYPE t_lines IS TABLE OF VARCHAR2(4000);
  PROCEDURE build_plan(p_run NUMBER);
  -- Plan as a script, for review. Read-only.
  FUNCTION  plan_script(p_run NUMBER) RETURN t_lines PIPELINED;
  -- p_dest: '+DATA_LOW' or '/u02/oradata/LOW/%b';  p_channels: DISK or SBT ALLOCATE clause text
  FUNCTION  rman_script(p_run NUMBER, p_dest VARCHAR2, p_until_scn NUMBER,
                        p_channel_clause VARCHAR2 DEFAULT 'DEVICE TYPE DISK', p_channels NUMBER DEFAULT 8) RETURN t_lines PIPELINED;
END pcopy_plan;
/

CREATE OR REPLACE PACKAGE BODY pcopy_plan AS

  c_mod CONSTANT VARCHAR2(30) := 'PCOPY_PLAN';

  g_seq NUMBER := 0;
  TYPE t_free IS TABLE OF NUMBER INDEX BY VARCHAR2(30);
  TYPE t_src  IS TABLE OF VARCHAR2(30) INDEX BY VARCHAR2(30);
  g_free t_free;      -- free GB of a skipped tablespace that may receive history
  g_new  t_src;       -- new tablespace name -> tablespace to copy attributes from

  TYPE t_tinfo IS RECORD (has_global BOOLEAN, online_blocked BOOLEAN);
  TYPE t_tinfo_tab IS TABLE OF t_tinfo INDEX BY VARCHAR2(300);
  g_tinfo t_tinfo_tab;

  FUNCTION q(p VARCHAR2) RETURN VARCHAR2 IS BEGIN RETURN pcopy_util.q(p); END q;

  FUNCTION table_info(p_run NUMBER, p_o VARCHAR2, p_t VARCHAR2) RETURN t_tinfo IS
    l_key VARCHAR2(300) := p_o || '.' || p_t;
    l_r t_tinfo; l_n NUMBER;
  BEGIN
    IF g_tinfo.EXISTS(l_key) THEN RETURN g_tinfo(l_key); END IF;
    SELECT COUNT(*) INTO l_n FROM pcopy_segment_map
    WHERE  run_id = p_run AND table_owner = p_o AND table_name = p_t AND is_global = 'Y' AND ROWNUM = 1;
    l_r.has_global := l_n > 0;
    SELECT COUNT(*) INTO l_n FROM dual
    WHERE  EXISTS (SELECT 1 FROM dba_indexes i WHERE i.table_owner = p_o AND i.table_name = p_t AND (i.index_type = 'DOMAIN' OR i.join_index = 'YES'))
    OR     EXISTS (SELECT 1 FROM dba_object_tables x WHERE x.owner = p_o AND x.table_name = p_t)
    OR     EXISTS (SELECT 1 FROM dba_tables x WHERE x.owner = p_o AND x.table_name = p_t AND x.iot_type IS NOT NULL)
    OR     EXISTS (SELECT 1 FROM dba_tab_cols c WHERE c.owner = p_o AND c.table_name = p_t
                   AND c.data_type_owner IS NOT NULL AND c.data_type_owner NOT IN ('SYS','PUBLIC'));
    l_r.online_blocked := l_n > 0;
    g_tinfo(l_key) := l_r;
    RETURN l_r;
  END table_info;

  FUNCTION add_step(p_run NUMBER, p_phase NUMBER, p_type VARCHAR2, p_owner VARCHAR2, p_obj VARCHAR2, p_part VARCHAR2,
                    p_src VARCHAR2, p_tgt VARCHAR2, p_gb NUMBER, p_lob_gb NUMBER, p_class VARCHAR2, p_mode VARCHAR2,
                    p_dep NUMBER, p_sql VARCHAR2, p_status VARCHAR2 DEFAULT 'PENDING', p_note VARCHAR2 DEFAULT NULL,
                    p_expected VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    l_id NUMBER;
  BEGIN
    g_seq := g_seq + 1;
    INSERT INTO pcopy_plan_step (run_id, seq, phase, step_type, owner, object_name, partition_name, source_ts, target_ts,
                                 est_gb, lob_gb, data_class, move_mode, dep_step_id, sql_text, status, note, expected_value)
    VALUES (p_run, g_seq, p_phase, p_type, p_owner, p_obj, p_part, p_src, p_tgt, NVL(p_gb,0), NVL(p_lob_gb,0), p_class, p_mode,
            p_dep, p_sql, p_status, p_note, p_expected)
    RETURNING step_id INTO l_id;
    RETURN l_id;
  END add_step;

  -- First fit into existing skipped tablespaces, otherwise a new one per year.
  FUNCTION pick_hist_ts(p_run NUMBER, p_gb NUMBER, p_bs NUMBER, p_enc VARCHAR2, p_hv DATE, p_src VARCHAR2) RETURN VARCHAR2 IS
    l_need NUMBER := p_gb * pcopy_util.cfg_num('SPACE_FACTOR');
    l_ts   VARCHAR2(30);
  BEGIN
    IF pcopy_util.cfg('PREFER_EXISTING_HIST_TS') = 'Y' THEN
      FOR c IN (SELECT tablespace_name FROM pcopy_ts_map
                WHERE run_id = p_run AND decision = 'SKIP' AND block_size = p_bs AND encrypted = p_enc AND ssm = 'AUTO'
                ORDER BY tablespace_name) LOOP
        IF g_free.EXISTS(c.tablespace_name) AND g_free(c.tablespace_name) >= l_need THEN
          g_free(c.tablespace_name) := g_free(c.tablespace_name) - l_need;
          RETURN c.tablespace_name;
        END IF;
      END LOOP;
    END IF;
    l_ts := pcopy_util.cfg('HIST_TS_PREFIX') || NVL(TO_CHAR(p_hv, 'YYYY'), 'OLD')
         || CASE WHEN p_bs <> 8192 THEN '_' || (p_bs / 1024) || 'K' END
         || CASE WHEN p_enc = 'YES' THEN '_E' END;
    IF NOT g_new.EXISTS(l_ts) THEN g_new(l_ts) := p_src; END IF;
    RETURN l_ts;
  END pick_hist_ts;

  PROCEDURE assign_targets(p_run NUMBER) IS
    l_suffix VARCHAR2(10) := pcopy_util.cfg('KEEP_TS_SUFFIX');
    l_tgt    VARCHAR2(30);
  BEGIN
    UPDATE pcopy_segment_map SET target_ts = NULL WHERE run_id = p_run AND target_ts IS NOT NULL;

    -- (a) recent data out of tablespaces that will be skipped
    UPDATE pcopy_segment_map s
    SET    s.target_ts = SUBSTR(s.tablespace_name, 1, 30 - LENGTH(l_suffix)) || l_suffix
    WHERE  s.run_id = p_run AND s.data_class = 'KEEP' AND s.role NOT IN ('OTHER','LOBINDEX')
    AND    s.tablespace_name IN (SELECT t.tablespace_name FROM pcopy_ts_map t WHERE t.run_id = p_run AND t.decision = 'SKIP');
    FOR r IN (SELECT DISTINCT tablespace_name, target_ts FROM pcopy_segment_map WHERE run_id = p_run AND target_ts IS NOT NULL) LOOP
      IF NOT g_new.EXISTS(r.target_ts) THEN g_new(r.target_ts) := r.tablespace_name; END IF;
    END LOOP;

    -- free space on existing history tablespaces
    g_free.DELETE;
    FOR r IN (SELECT t.tablespace_name, NVL(t.max_gb,0) - NVL(t.used_gb,0) free_gb
              FROM pcopy_ts_map t WHERE t.run_id = p_run AND t.decision = 'SKIP') LOOP
      g_free(r.tablespace_name) := r.free_gb;
    END LOOP;

    -- (b) plain history out of tablespaces marked MOVE_HIST_OUT
    FOR u IN (SELECT s.table_owner, s.table_name, s.table_partition, SUM(s.gb) gb, MAX(t.block_size) bs, MAX(t.encrypted) enc,
                     MAX(m.high_value_dt) hv, MIN(s.tablespace_name) src
              FROM   pcopy_segment_map s
              JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name
              JOIN   pcopy_partition_map m ON m.run_id = s.run_id AND m.table_owner = s.table_owner
                                          AND m.table_name = s.table_name AND m.partition_name = s.table_partition
              WHERE  s.run_id = p_run AND s.data_class = 'HIST' AND s.role <> 'LOBINDEX' AND m.complex_reason IS NULL
              GROUP  BY s.table_owner, s.table_name, s.table_partition
              HAVING COUNT(CASE WHEN t.action = 'MOVE_HIST_OUT' THEN 1 END) > 0
              ORDER  BY MAX(m.high_value_dt)) LOOP
      l_tgt := pick_hist_ts(p_run, u.gb, u.bs, u.enc, u.hv, u.src);
      UPDATE pcopy_segment_map s SET s.target_ts = l_tgt
      WHERE  s.run_id = p_run AND s.table_owner = u.table_owner AND s.table_name = u.table_name
      AND    s.table_partition = u.table_partition AND s.role <> 'LOBINDEX'
      AND    s.tablespace_name IN (SELECT t.tablespace_name FROM pcopy_ts_map t WHERE t.run_id = p_run AND t.decision <> 'SKIP');
    END LOOP;

    -- (c) HIST partitions split across the boundary: pull the restored part into the skipped tablespace
    IF pcopy_util.cfg('FIX_HIST_SPLIT') = 'Y' THEN
      FOR u IN (SELECT s.table_owner, s.table_name, s.table_partition,
                       MIN(CASE WHEN s.role IN ('TABLE_PART','TABLE_SUB') AND t.decision = 'SKIP' THEN s.tablespace_name END) tab_skip,
                       MIN(CASE WHEN t.decision = 'SKIP' THEN s.tablespace_name END) any_skip
                FROM   pcopy_segment_map s
                JOIN   pcopy_ts_map t ON t.run_id = s.run_id AND t.tablespace_name = s.tablespace_name
                WHERE  s.run_id = p_run AND s.data_class = 'HIST' AND s.role <> 'LOBINDEX' AND s.target_ts IS NULL
                GROUP  BY s.table_owner, s.table_name, s.table_partition
                HAVING COUNT(CASE WHEN t.decision = 'SKIP' THEN 1 END) > 0
                AND    COUNT(CASE WHEN t.decision <> 'SKIP' THEN 1 END) > 0) LOOP
        UPDATE pcopy_segment_map s SET s.target_ts = NVL(u.tab_skip, u.any_skip)
        WHERE  s.run_id = p_run AND s.table_owner = u.table_owner AND s.table_name = u.table_name
        AND    s.table_partition = u.table_partition AND s.role <> 'LOBINDEX'
        AND    s.tablespace_name IN (SELECT t.tablespace_name FROM pcopy_ts_map t WHERE t.run_id = p_run AND t.decision <> 'SKIP');
      END LOOP;
    END IF;
    COMMIT;
  END assign_targets;

  -- LOB clause for the rows that move. Sets p_manual when a column cannot be named simply.
  FUNCTION lob_clause(p_run NUMBER, p_o VARCHAR2, p_t VARCHAR2, p_p VARCHAR2, p_s VARCHAR2, p_manual IN OUT BOOLEAN) RETURN VARCHAR2 IS
    l_txt VARCHAR2(32767); l_ok NUMBER;
  BEGIN
    FOR l IN (SELECT lob_column, target_ts FROM pcopy_segment_map
              WHERE  run_id = p_run AND table_owner = p_o AND table_name = p_t
              AND    NVL(table_partition,'~') = NVL(p_p,'~') AND NVL(table_subpartition,'~') = NVL(p_s,'~')
              AND    role IN ('LOB','LOB_PART','LOB_SUB') AND target_ts IS NOT NULL
              ORDER  BY lob_column) LOOP
      SELECT COUNT(*) INTO l_ok FROM dba_tab_cols c
      WHERE  c.owner = p_o AND c.table_name = p_t AND c.column_name = l.lob_column
      AND    c.hidden_column = 'NO' AND c.data_type IN ('CLOB','BLOB','NCLOB');
      IF l_ok = 0 THEN p_manual := TRUE; END IF;
      l_txt := l_txt || ' LOB (' || q(l.lob_column) || ') STORE AS (TABLESPACE ' || q(l.target_ts) || ')';
    END LOOP;
    RETURN l_txt;
  END lob_clause;

  PROCEDURE steps_partition_moves(p_run NUMBER) IS
    l_par    NUMBER := pcopy_util.cfg_num('PARALLEL_DEGREE');
    l_tab_ts VARCHAR2(30); l_tab_tgt VARCHAR2(30); l_lob_gb NUMBER; l_tab_gb NUMBER;
    l_lob    VARCHAR2(32767); l_manual BOOLEAN; l_mode VARCHAR2(4); l_sql VARCHAR2(32767);
    l_tail   VARCHAR2(200); l_move NUMBER; l_info t_tinfo; l_status VARCHAR2(10); l_note VARCHAR2(400); l_moved BOOLEAN;
  BEGIN
    FOR u IN (SELECT table_owner, table_name, table_partition, table_subpartition, MAX(data_class) data_class
              FROM   pcopy_segment_map
              WHERE  run_id = p_run AND table_partition IS NOT NULL AND is_global = 'N'
              AND    role IN ('TABLE_PART','TABLE_SUB','LOB_PART','LOB_SUB','INDEX_PART','INDEX_SUB')
              GROUP  BY table_owner, table_name, table_partition, table_subpartition
              HAVING COUNT(target_ts) > 0
              ORDER  BY table_owner, table_name, table_partition, table_subpartition) LOOP
      l_info := table_info(p_run, u.table_owner, u.table_name);
      l_manual := FALSE; l_move := NULL; l_moved := FALSE; l_status := 'PENDING'; l_note := NULL;

      SELECT MAX(CASE WHEN role IN ('TABLE_PART','TABLE_SUB') THEN tablespace_name END),
             MAX(CASE WHEN role IN ('TABLE_PART','TABLE_SUB') THEN target_ts END),
             SUM(CASE WHEN role IN ('TABLE_PART','TABLE_SUB') THEN gb ELSE 0 END),
             SUM(CASE WHEN role IN ('LOB_PART','LOB_SUB') THEN gb ELSE 0 END)
      INTO   l_tab_ts, l_tab_tgt, l_tab_gb, l_lob_gb
      FROM   pcopy_segment_map
      WHERE  run_id = p_run AND table_owner = u.table_owner AND table_name = u.table_name
      AND    table_partition = u.table_partition AND NVL(table_subpartition,'~') = NVL(u.table_subpartition,'~');

      l_lob := lob_clause(p_run, u.table_owner, u.table_name, u.table_partition, u.table_subpartition, l_manual);
      l_mode := pcopy_util.cfg(CASE WHEN u.data_class = 'HIST' THEN 'MOVE_MODE_HIST' ELSE 'MOVE_MODE_KEEP' END);

      IF l_info.online_blocked AND l_mode = 'HOT' THEN
        IF u.data_class = 'KEEP' THEN
          l_status := 'MANUAL'; l_note := 'ONLINE not allowed on this table and data is recent: plan an outage';
        END IF;
        l_mode := 'COLD';
      END IF;
      IF l_manual THEN
        l_status := 'MANUAL'; l_note := 'XMLType, object or hidden LOB column: review the storage clause by hand';
      END IF;

      IF l_tab_tgt IS NOT NULL OR l_lob IS NOT NULL THEN
        l_moved := TRUE;
        l_tail := CASE
                    WHEN l_mode = 'HOT' THEN ' UPDATE INDEXES PARALLEL ' || l_par || ' ONLINE'
                    WHEN l_info.has_global THEN ' UPDATE GLOBAL INDEXES PARALLEL ' || l_par
                    ELSE ' PARALLEL ' || l_par END;
        l_sql := 'ALTER TABLE ' || q(u.table_owner) || '.' || q(u.table_name)
              || CASE WHEN u.table_subpartition IS NOT NULL
                      THEN ' MOVE SUBPARTITION ' || q(u.table_subpartition)
                      ELSE ' MOVE PARTITION ' || q(u.table_partition) END
              || ' TABLESPACE ' || q(NVL(l_tab_tgt, l_tab_ts)) || l_lob || l_tail;
        l_move := add_step(p_run, 40, CASE WHEN u.table_subpartition IS NOT NULL THEN 'MOVE_SUBPART' ELSE 'MOVE_PART' END,
                           u.table_owner, u.table_name, NVL(u.table_subpartition, u.table_partition), l_tab_ts,
                           NVL(l_tab_tgt, l_tab_ts), l_tab_gb + l_lob_gb, l_lob_gb, u.data_class, l_mode, NULL, l_sql, l_status, l_note);
      END IF;

      -- Local index partitions: relocate those with a target. COLD also rebuilds what the move made UNUSABLE.
      FOR i IN (SELECT seg_owner, seg_name, seg_partition, role, tablespace_name, target_ts, gb
                FROM   pcopy_segment_map
                WHERE  run_id = p_run AND table_owner = u.table_owner AND table_name = u.table_name
                AND    table_partition = u.table_partition AND NVL(table_subpartition,'~') = NVL(u.table_subpartition,'~')
                AND    role IN ('INDEX_PART','INDEX_SUB') AND is_global = 'N'
                ORDER  BY seg_owner, seg_name) LOOP
        IF i.target_ts IS NOT NULL OR (l_moved AND l_mode = 'COLD') THEN
          l_sql := 'ALTER INDEX ' || q(i.seg_owner) || '.' || q(i.seg_name) || ' REBUILD '
                || CASE WHEN i.role = 'INDEX_SUB' THEN 'SUBPARTITION ' ELSE 'PARTITION ' END || q(i.seg_partition)
                || ' TABLESPACE ' || q(NVL(i.target_ts, i.tablespace_name)) || ' PARALLEL ' || l_par
                || CASE WHEN l_mode = 'HOT' THEN ' ONLINE' END;
          DECLARE l_x NUMBER; BEGIN
            l_x := add_step(p_run, 40, 'REBUILD_LOCAL', i.seg_owner, i.seg_name, i.seg_partition, i.tablespace_name,
                            NVL(i.target_ts, i.tablespace_name), i.gb, 0, u.data_class, l_mode, l_move, l_sql, l_status, l_note);
          END;
        END IF;
      END LOOP;
    END LOOP;
    COMMIT;
  END steps_partition_moves;

  PROCEDURE steps_table_moves(p_run NUMBER) IS
    l_par NUMBER := pcopy_util.cfg_num('PARALLEL_DEGREE');
    l_tab_ts VARCHAR2(30); l_tab_tgt VARCHAR2(30); l_gb NUMBER; l_lob_gb NUMBER; l_lob VARCHAR2(32767);
    l_manual BOOLEAN; l_info t_tinfo; l_long NUMBER; l_status VARCHAR2(10); l_note VARCHAR2(400); l_x NUMBER;
  BEGIN
    FOR u IN (SELECT table_owner, table_name FROM pcopy_segment_map
              WHERE  run_id = p_run AND role IN ('TABLE','LOB')
              GROUP  BY table_owner, table_name HAVING COUNT(target_ts) > 0
              ORDER  BY table_owner, table_name) LOOP
      l_info := table_info(p_run, u.table_owner, u.table_name);
      l_manual := FALSE; l_status := 'PENDING'; l_note := NULL;
      SELECT MAX(CASE WHEN role = 'TABLE' THEN tablespace_name END), MAX(CASE WHEN role = 'TABLE' THEN target_ts END),
             SUM(gb), SUM(CASE WHEN role = 'LOB' THEN gb ELSE 0 END)
      INTO   l_tab_ts, l_tab_tgt, l_gb, l_lob_gb
      FROM   pcopy_segment_map
      WHERE  run_id = p_run AND table_owner = u.table_owner AND table_name = u.table_name AND role IN ('TABLE','LOB');
      l_lob := lob_clause(p_run, u.table_owner, u.table_name, NULL, NULL, l_manual);
      SELECT COUNT(*) INTO l_long FROM dba_tab_cols
      WHERE  owner = u.table_owner AND table_name = u.table_name AND data_type IN ('LONG','LONG RAW');
      IF l_long > 0 THEN
        l_status := 'MANUAL'; l_note := 'LONG column: MOVE is impossible. Convert to LOB or use Data Pump';
      ELSIF l_info.online_blocked THEN
        l_status := 'MANUAL'; l_note := 'ONLINE not allowed on this table: plan an outage';
      ELSIF l_manual THEN
        l_status := 'MANUAL'; l_note := 'XMLType, object or hidden LOB column: review the storage clause by hand';
      END IF;
      l_x := add_step(p_run, 40, 'MOVE_TABLE', u.table_owner, u.table_name, NULL, l_tab_ts, NVL(l_tab_tgt, l_tab_ts), l_gb, l_lob_gb,
                      'KEEP', 'HOT', NULL,
                      'ALTER TABLE ' || q(u.table_owner) || '.' || q(u.table_name) || ' MOVE ONLINE TABLESPACE '
                      || q(NVL(l_tab_tgt, l_tab_ts)) || l_lob || ' PARALLEL ' || l_par || ' UPDATE INDEXES',
                      l_status, l_note);
    END LOOP;
    COMMIT;
  END steps_table_moves;

  PROCEDURE steps_global_indexes(p_run NUMBER) IS
    l_par NUMBER := pcopy_util.cfg_num('PARALLEL_DEGREE'); l_x NUMBER;
  BEGIN
    FOR i IN (SELECT seg_owner, seg_name, seg_partition, role, tablespace_name, target_ts, gb
              FROM   pcopy_segment_map
              WHERE  run_id = p_run AND target_ts IS NOT NULL
              AND   (role = 'INDEX' OR (role = 'INDEX_PART' AND is_global = 'Y'))
              ORDER  BY seg_owner, seg_name, seg_partition) LOOP
      l_x := add_step(p_run, 50, 'REBUILD_GLOBAL', i.seg_owner, i.seg_name, i.seg_partition, i.tablespace_name, i.target_ts, i.gb, 0,
                      'KEEP', 'HOT', NULL,
                      'ALTER INDEX ' || q(i.seg_owner) || '.' || q(i.seg_name) || ' REBUILD '
                      || CASE WHEN i.seg_partition IS NOT NULL THEN 'PARTITION ' || q(i.seg_partition) || ' ' END
                      || 'TABLESPACE ' || q(i.target_ts) || ' PARALLEL ' || l_par || ' ONLINE');
    END LOOP;
    COMMIT;
  END steps_global_indexes;

  -- Where new partitions of this table should go after the plan
  FUNCTION latest_ts(p_run NUMBER, p_o VARCHAR2, p_t VARCHAR2, p_fallback_src VARCHAR2) RETURN VARCHAR2 IS
    l_ts VARCHAR2(30);
    l_sfx VARCHAR2(10) := pcopy_util.cfg('KEEP_TS_SUFFIX');
  BEGIN
    SELECT MAX(NVL(s.target_ts, s.tablespace_name)) KEEP (DENSE_RANK LAST ORDER BY m.partition_position)
    INTO   l_ts
    FROM   pcopy_segment_map s
    JOIN   pcopy_partition_map m ON m.run_id = s.run_id AND m.table_owner = s.table_owner
                                AND m.table_name = s.table_name AND m.partition_name = s.table_partition
    WHERE  s.run_id = p_run AND s.table_owner = p_o AND s.table_name = p_t
    AND    s.role IN ('TABLE_PART','TABLE_SUB') AND s.data_class = 'KEEP';
    IF l_ts IS NULL THEN
      l_ts := SUBSTR(p_fallback_src, 1, 30 - LENGTH(l_sfx)) || l_sfx;
      IF NOT g_new.EXISTS(l_ts) THEN g_new(l_ts) := p_fallback_src; END IF;
    END IF;
    RETURN l_ts;
  END latest_ts;

  PROCEDURE steps_defaults(p_run NUMBER) IS
    l_ts VARCHAR2(30); l_x NUMBER;
  BEGIN
    FOR r IN (SELECT pt.owner, pt.table_name, pt.def_tablespace_name
              FROM   dba_part_tables pt
              JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = pt.def_tablespace_name AND t.decision = 'SKIP') LOOP
      l_ts := latest_ts(p_run, r.owner, r.table_name, r.def_tablespace_name);
      l_x := add_step(p_run, 60, 'DEFAULT_ATTR', r.owner, r.table_name, NULL, r.def_tablespace_name, l_ts, 0, 0, NULL, NULL, NULL,
                      'ALTER TABLE ' || q(r.owner) || '.' || q(r.table_name) || ' MODIFY DEFAULT ATTRIBUTES TABLESPACE ' || q(l_ts));
    END LOOP;
    FOR r IN (SELECT pi.owner, pi.index_name, pi.def_tablespace_name, i.table_owner, i.table_name
              FROM   dba_part_indexes pi
              JOIN   dba_indexes i ON i.owner = pi.owner AND i.index_name = pi.index_name
              JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = pi.def_tablespace_name AND t.decision = 'SKIP') LOOP
      l_ts := latest_ts(p_run, r.table_owner, r.table_name, r.def_tablespace_name);
      l_x := add_step(p_run, 60, 'DEFAULT_ATTR', r.owner, r.index_name, NULL, r.def_tablespace_name, l_ts, 0, 0, NULL, NULL, NULL,
                      'ALTER INDEX ' || q(r.owner) || '.' || q(r.index_name) || ' MODIFY DEFAULT ATTRIBUTES TABLESPACE ' || q(l_ts));
    END LOOP;
    FOR r IN (SELECT pl.table_owner, pl.table_name, pl.column_name, pl.def_tablespace_name
              FROM   dba_part_lobs pl
              JOIN   pcopy_ts_map t ON t.run_id = p_run AND t.tablespace_name = pl.def_tablespace_name AND t.decision = 'SKIP') LOOP
      l_ts := latest_ts(p_run, r.table_owner, r.table_name, r.def_tablespace_name);
      l_x := add_step(p_run, 60, 'DEFAULT_ATTR', r.table_owner, r.table_name, NULL, r.def_tablespace_name, l_ts, 0, 0, NULL, NULL, NULL,
                      'ALTER TABLE ' || q(r.table_owner) || '.' || q(r.table_name) || ' MODIFY DEFAULT ATTRIBUTES LOB ('
                      || q(r.column_name) || ') (TABLESPACE ' || q(l_ts) || ')');
    END LOOP;
    -- Interval tables whose recent partitions move: new interval partitions must follow
    FOR r IN (SELECT DISTINCT s.table_owner, s.table_name, s.tablespace_name
              FROM   pcopy_segment_map s
              JOIN   pcopy_partition_map m ON m.run_id = s.run_id AND m.table_owner = s.table_owner
                                          AND m.table_name = s.table_name AND m.partition_name = s.table_partition
              WHERE  s.run_id = p_run AND s.data_class = 'KEEP' AND s.target_ts IS NOT NULL
              AND    s.role IN ('TABLE_PART','TABLE_SUB') AND m.interval_expr IS NOT NULL) LOOP
      l_ts := latest_ts(p_run, r.table_owner, r.table_name, r.tablespace_name);
      l_x := add_step(p_run, 60, 'DEFAULT_ATTR', r.table_owner, r.table_name, NULL, r.tablespace_name, l_ts, 0, 0, NULL, NULL, NULL,
                      'ALTER TABLE ' || q(r.table_owner) || '.' || q(r.table_name) || ' SET STORE IN (' || q(l_ts) || ')');
    END LOOP;
    COMMIT;
  END steps_defaults;

  FUNCTION degree_clause(p_degree VARCHAR2) RETURN VARCHAR2 IS
    l VARCHAR2(40) := TRIM(p_degree);
  BEGIN
    RETURN CASE WHEN l = '1' THEN 'NOPARALLEL' WHEN l = 'DEFAULT' THEN 'PARALLEL' ELSE 'PARALLEL ' || l END;
  END degree_clause;

  PROCEDURE steps_degree(p_run NUMBER) IS
    l_x NUMBER;
  BEGIN
    FOR r IN (SELECT DISTINCT t.owner, t.table_name, TRIM(t.degree) degree
              FROM   pcopy_plan_step s JOIN dba_tables t ON t.owner = s.owner AND t.table_name = s.object_name
              WHERE  s.run_id = p_run AND s.step_type LIKE 'MOVE%') LOOP
      l_x := add_step(p_run, 70, 'RESTORE_DEGREE', r.owner, r.table_name, NULL, NULL, NULL, 0, 0, NULL, NULL, NULL,
                      'ALTER TABLE ' || q(r.owner) || '.' || q(r.table_name) || ' ' || degree_clause(r.degree),
                      p_expected => r.degree);
    END LOOP;
    FOR r IN (SELECT DISTINCT i.owner, i.index_name, TRIM(i.degree) degree
              FROM   pcopy_plan_step s JOIN dba_indexes i ON i.owner = s.owner AND i.index_name = s.object_name
              WHERE  s.run_id = p_run AND s.step_type LIKE 'REBUILD%') LOOP
      l_x := add_step(p_run, 70, 'RESTORE_DEGREE', r.owner, r.index_name, NULL, NULL, NULL, 0, 0, NULL, NULL, NULL,
                      'ALTER INDEX ' || q(r.owner) || '.' || q(r.index_name) || ' ' || degree_clause(r.degree),
                      p_expected => r.degree);
    END LOOP;
    COMMIT;
  END steps_degree;

  PROCEDURE steps_tablespaces(p_run NUMBER) IS
    l_name VARCHAR2(30); l_x NUMBER; l_bs NUMBER; l_enc VARCHAR2(3); l_n NUMBER;
    l_prefix VARCHAR2(30) := pcopy_util.cfg('HIST_TS_PREFIX');
  BEGIN
    -- New tablespaces. Phases sort before moves, regardless of insert order.
    l_name := g_new.FIRST;
    WHILE l_name IS NOT NULL LOOP
      SELECT COUNT(*) INTO l_n FROM dba_tablespaces WHERE tablespace_name = l_name;
      IF l_n = 0 THEN
        SELECT block_size, encrypted INTO l_bs, l_enc FROM pcopy_ts_map WHERE run_id = p_run AND tablespace_name = g_new(l_name);
        l_x := add_step(p_run, 10, 'CREATE_TS', NULL, l_name, NULL, g_new(l_name), l_name, 0, 0, NULL, NULL, NULL,
                        'CREATE BIGFILE TABLESPACE ' || q(l_name) || ' DATAFILE SIZE 10G AUTOEXTEND ON NEXT 10G MAXSIZE UNLIMITED'
                        || ' BLOCKSIZE ' || l_bs || ' EXTENT MANAGEMENT LOCAL AUTOALLOCATE SEGMENT SPACE MANAGEMENT AUTO'
                        || CASE WHEN l_enc = 'YES' THEN ' ENCRYPTION USING ''AES256'' ENCRYPT' END);
      END IF;
      l_name := g_new.NEXT(l_name);
    END LOOP;

    -- Owner quota on every target: a MOVE consumes the quota of the table owner, not of PCOPY.
    FOR r IN (SELECT DISTINCT s.owner, s.target_ts FROM pcopy_plan_step s
              WHERE  s.run_id = p_run AND s.target_ts IS NOT NULL AND s.owner IS NOT NULL AND s.phase IN (40,50)
              AND    NOT EXISTS (SELECT 1 FROM dba_sys_privs p WHERE p.grantee = s.owner AND p.privilege = 'UNLIMITED TABLESPACE')
              AND    NOT EXISTS (SELECT 1 FROM dba_ts_quotas q WHERE q.username = s.owner AND q.tablespace_name = s.target_ts AND q.max_bytes = -1)) LOOP
      l_x := add_step(p_run, 20, 'QUOTA', r.owner, NULL, NULL, NULL, r.target_ts, 0, 0, NULL, NULL, NULL,
                      'ALTER USER ' || q(r.owner) || ' QUOTA UNLIMITED ON ' || q(r.target_ts));
    END LOOP;

    -- Read-only tablespaces touched by the plan: open, then return to read-only.
    FOR r IN (SELECT DISTINCT t.tablespace_name
              FROM   pcopy_ts_map t
              WHERE  t.run_id = p_run AND t.status = 'READ ONLY'
              AND    EXISTS (SELECT 1 FROM pcopy_plan_step s WHERE s.run_id = p_run AND s.phase IN (40,50)
                             AND (s.source_ts = t.tablespace_name OR s.target_ts = t.tablespace_name))) LOOP
      l_x := add_step(p_run, 30, 'TS_RW', NULL, r.tablespace_name, NULL, NULL, r.tablespace_name, 0, 0, NULL, NULL, NULL,
                      'ALTER TABLESPACE ' || q(r.tablespace_name) || ' READ WRITE');
      l_x := add_step(p_run, 80, 'TS_RO', NULL, r.tablespace_name, NULL, NULL, r.tablespace_name, 0, 0, NULL, NULL, NULL,
                      'ALTER TABLESPACE ' || q(r.tablespace_name) || ' READ ONLY');
    END LOOP;
    -- New history tablespaces end up read-only as well
    l_name := g_new.FIRST;
    WHILE l_name IS NOT NULL LOOP
      IF l_name LIKE l_prefix || '%' THEN
        l_x := add_step(p_run, 80, 'TS_RO', NULL, l_name, NULL, NULL, l_name, 0, 0, NULL, NULL, NULL,
                        'ALTER TABLESPACE ' || q(l_name) || ' READ ONLY');
      END IF;
      l_name := g_new.NEXT(l_name);
    END LOOP;
    COMMIT;
  END steps_tablespaces;

  PROCEDURE build_plan(p_run NUMBER) IS
    l_done NUMBER; l_steps NUMBER; l_gb NUMBER; l_manual NUMBER;
  BEGIN
    SELECT COUNT(*) INTO l_done FROM pcopy_plan_step WHERE run_id = p_run AND status IN ('DONE','RUNNING','FAILED');
    IF l_done > 0 THEN
      RAISE_APPLICATION_ERROR(-20120, 'Run ' || p_run || ' already executed steps. Start a new mapping');
    END IF;
    DELETE FROM pcopy_plan_step WHERE run_id = p_run;
    g_seq := 0; g_new.DELETE; g_tinfo.DELETE; g_free.DELETE;

    pcopy_util.write_log(p_run, 'INFO', c_mod, 'START', 'Building plan');
    assign_targets(p_run);
    steps_partition_moves(p_run);
    steps_table_moves(p_run);
    steps_global_indexes(p_run);
    steps_defaults(p_run);
    steps_degree(p_run);
    steps_tablespaces(p_run);

    SELECT COUNT(*), NVL(SUM(est_gb),0), COUNT(CASE WHEN status = 'MANUAL' THEN 1 END)
    INTO   l_steps, l_gb, l_manual FROM pcopy_plan_step WHERE run_id = p_run;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'END', l_steps || ' steps, ' || ROUND(l_gb) || ' GB to rewrite, ' || l_manual || ' manual');
    UPDATE pcopy_run SET status = 'PLANNED' WHERE run_id = p_run;
    COMMIT;
  EXCEPTION WHEN OTHERS THEN
    pcopy_util.log_error(p_run, c_mod, 'BUILD_PLAN');
    ROLLBACK;
    RAISE;
  END build_plan;

  FUNCTION plan_script(p_run NUMBER) RETURN t_lines PIPELINED IS
  BEGIN
    FOR s IN (SELECT * FROM pcopy_plan_step WHERE run_id = p_run ORDER BY phase, seq) LOOP
      PIPE ROW('-- step ' || s.step_id || ' phase ' || s.phase || ' ' || s.step_type || ' ' || s.status
               || ' est_gb=' || ROUND(s.est_gb,1) || CASE WHEN s.note IS NOT NULL THEN ' NOTE: ' || s.note END);
      PIPE ROW(CASE WHEN s.status = 'MANUAL' THEN '-- ' END || DBMS_LOB.SUBSTR(s.sql_text, 3900, 1) || ';');
    END LOOP;
    RETURN;
  END plan_script;

  FUNCTION rman_script(p_run NUMBER, p_dest VARCHAR2, p_until_scn NUMBER,
                       p_channel_clause VARCHAR2 DEFAULT 'DEVICE TYPE DISK', p_channels NUMBER DEFAULT 8) RETURN t_lines PIPELINED IS
    l_map_scn NUMBER; l_cnt NUMBER;
    CURSOR c_skip IS
      SELECT tablespace_name, ROW_NUMBER() OVER (ORDER BY tablespace_name) rn, COUNT(*) OVER () tot
      FROM   pcopy_ts_map WHERE run_id = p_run AND decision = 'SKIP';
  BEGIN
    SELECT map_scn INTO l_map_scn FROM pcopy_run WHERE run_id = p_run;
    IF p_until_scn <= l_map_scn THEN
      RAISE_APPLICATION_ERROR(-20121, 'UNTIL SCN ' || p_until_scn || ' must be above the mapping SCN ' || l_map_scn);
    END IF;
    SELECT COUNT(*) INTO l_cnt FROM pcopy_ts_map WHERE run_id = p_run AND decision = 'SKIP';

    PIPE ROW('# Generated from PCOPY run ' || p_run || ', mapping SCN ' || l_map_scn);
    PIPE ROW('RUN {');
    FOR i IN 1 .. p_channels LOOP
      PIPE ROW('  ALLOCATE CHANNEL c' || i || ' ' || p_channel_clause || ';');
    END LOOP;
    PIPE ROW('  SET UNTIL SCN ' || p_until_scn || ';');
    -- Only restored tablespaces get a new name, so SWITCH does not touch skipped files
    FOR r IN (SELECT tablespace_name FROM pcopy_ts_map
              WHERE run_id = p_run AND decision <> 'SKIP' AND contents <> 'TEMPORARY' ORDER BY 1) LOOP
      PIPE ROW('  SET NEWNAME FOR TABLESPACE ' || q(r.tablespace_name) || ' TO ''' || p_dest || ''';');
    END LOOP;
    IF l_cnt = 0 THEN
      PIPE ROW('  RESTORE DATABASE;');
      PIPE ROW('  SWITCH DATAFILE ALL;');
      PIPE ROW('  RECOVER DATABASE;');
    ELSE
      PIPE ROW('  RESTORE DATABASE SKIP TABLESPACE');
      FOR r IN c_skip LOOP
        PIPE ROW('    ' || q(r.tablespace_name) || CASE WHEN r.rn < r.tot THEN ',' ELSE ';' END);
      END LOOP;
      PIPE ROW('  SWITCH DATAFILE ALL;');
      PIPE ROW('  RECOVER DATABASE SKIP FOREVER TABLESPACE');
      FOR r IN c_skip LOOP
        PIPE ROW('    ' || q(r.tablespace_name) || CASE WHEN r.rn < r.tot THEN ',' ELSE ';' END);
      END LOOP;
    END IF;
    PIPE ROW('}');
    RETURN;
  END rman_script;

END pcopy_plan;
/
SHOW ERRORS

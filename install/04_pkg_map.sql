-- =============================================================================
-- 04_pkg_map.sql  -  PCOPY_MAP: classify partitions, map every storage unit,
--                    classify tablespaces and recommend a decision per tablespace.
-- Writes only to PCOPY tables. No change to application objects.
-- =============================================================================
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pcopy_map AS
  FUNCTION  run_mapping(p_note VARCHAR2 DEFAULT NULL) RETURN NUMBER;
  -- Manual override of a recommendation.
  -- p_decision: SKIP / RESTORE / RESTORE_DROP;  p_action: NONE / LEAVE / MOVE_KEEP_OUT / MOVE_HIST_OUT
  PROCEDURE set_ts_decision(p_run NUMBER, p_ts VARCHAR2, p_decision VARCHAR2, p_action VARCHAR2, p_reason VARCHAR2);
END pcopy_map;
/

CREATE OR REPLACE PACKAGE BODY pcopy_map AS

  c_mod CONSTANT VARCHAR2(30) := 'PCOPY_MAP';
  c_gb  CONSTANT NUMBER := 1073741824;

  FUNCTION get_cutoff RETURN DATE IS
    l_fixed VARCHAR2(30) := pcopy_util.cfg('CUTOFF_FIXED_DATE');
  BEGIN
    IF l_fixed IS NOT NULL THEN
      RETURN TO_DATE(l_fixed, 'YYYY-MM-DD');
    END IF;
    RETURN ADD_MONTHS(TRUNC(SYSDATE, 'MM'), -pcopy_util.cfg_num('CUTOFF_MONTHS'));
  END get_cutoff;

  -- Evaluates a partition bound into a date. Returns NULL when it cannot.
  FUNCTION hv_to_date(p_hv VARCHAR2, p_fmt VARCHAR2) RETURN DATE IS
    l_d DATE;
  BEGIN
    IF p_fmt IS NULL THEN
      EXECUTE IMMEDIATE 'SELECT CAST(' || p_hv || ' AS DATE) FROM dual' INTO l_d;
    ELSE
      l_d := TO_DATE(TRIM(BOTH '''' FROM TRIM(p_hv)), p_fmt);
    END IF;
    RETURN l_d;
  EXCEPTION WHEN OTHERS THEN RETURN NULL;
  END hv_to_date;

  PROCEDURE snap_segments(p_run NUMBER) IS
  BEGIN
    INSERT /*+ APPEND */ INTO pcopy_seg_snap (run_id, owner, segment_name, partition_name, segment_type, tablespace_name, bytes)
    SELECT p_run, owner, segment_name, partition_name, segment_type, tablespace_name, bytes FROM dba_segments;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'SNAP_SEGMENTS', SQL%ROWCOUNT || ' segments');
    COMMIT;
  END snap_segments;

  PROCEDURE classify_partitions(p_run NUMBER, p_cutoff DATE) IS
    l_long LONG;
    l_hv VARCHAR2(32767); l_date DATE; l_class VARCHAR2(4); l_reason VARCHAR2(60);
    l_n  PLS_INTEGER := 0; l_rows PLS_INTEGER;
  BEGIN
    -- HIGH_VALUE is read by key below: a LONG column in an ANSI join can raise ORA-00997.
    FOR r IN (
      SELECT tp.table_owner, tp.table_name, tp.partition_name, tp.partition_position, tp.composite,
             pt.partitioning_type, pt.partitioning_key_count, pt.interval, tc.data_type key_type,
             rr.key_format, rr.force_class
      FROM   dba_tab_partitions tp
      JOIN   dba_part_tables pt ON pt.owner = tp.table_owner AND pt.table_name = tp.table_name
      JOIN   dba_users u ON u.username = tp.table_owner AND u.oracle_maintained = 'N'
      LEFT JOIN dba_part_key_columns kc ON kc.owner = tp.table_owner AND kc.name = tp.table_name
                                       AND TRIM(kc.object_type) = 'TABLE' AND kc.column_position = 1
      LEFT JOIN dba_tab_cols tc ON tc.owner = kc.owner AND tc.table_name = kc.name AND tc.column_name = kc.column_name
      LEFT JOIN pcopy_table_rule rr ON rr.owner = tp.table_owner AND rr.table_name = tp.table_name
      WHERE  tp.table_name NOT LIKE 'BIN$%'
    ) LOOP
      SELECT high_value INTO l_long FROM dba_tab_partitions
      WHERE  table_owner = r.table_owner AND table_name = r.table_name AND partition_name = r.partition_name;
      l_hv := l_long;
      l_date := NULL; l_class := 'KEEP';

      IF r.force_class IS NOT NULL THEN
        l_class := r.force_class; l_reason := 'RULE_FORCED';
      ELSIF r.partitioning_type = 'REFERENCE' THEN
        l_reason := 'REFERENCE_PENDING';                -- resolved below from the parent
      ELSIF r.partitioning_type <> 'RANGE' THEN
        l_reason := 'NOT_RANGE_' || r.partitioning_type;
      ELSIF r.partitioning_key_count > 1 THEN
        l_reason := 'MULTI_COLUMN_KEY';
      ELSIF TRIM(l_hv) = 'MAXVALUE' THEN
        l_reason := 'MAXVALUE';
      ELSIF r.key_format IS NULL AND r.key_type <> 'DATE' AND r.key_type NOT LIKE 'TIMESTAMP%' THEN
        l_reason := 'NON_DATE_KEY_NO_RULE';
      ELSE
        l_date := hv_to_date(l_hv, r.key_format);
        IF l_date IS NULL THEN
          l_reason := 'BOUND_NOT_PARSEABLE';
        ELSIF l_date <= p_cutoff THEN
          l_class := 'HIST'; l_reason := 'BOUND_LE_CUTOFF';
        ELSE
          l_reason := 'BOUND_GT_CUTOFF';
        END IF;
      END IF;

      INSERT INTO pcopy_partition_map
        (run_id, table_owner, table_name, partition_name, partition_position, is_composite, partitioning_type,
         interval_expr, key_type, high_value, high_value_dt, data_class, class_reason)
      VALUES
        (p_run, r.table_owner, r.table_name, r.partition_name, r.partition_position, r.composite, r.partitioning_type,
         r.interval, r.key_type, SUBSTR(l_hv, 1, 4000), l_date, l_class, l_reason);

      l_n := l_n + 1;
      IF MOD(l_n, 5000) = 0 THEN COMMIT; END IF;
    END LOOP;
    COMMIT;

    -- A table must keep at least one partition: ORA-14083 forbids dropping the last one.
    UPDATE pcopy_partition_map m SET data_class = 'KEEP', class_reason = 'LAST_PARTITION_PRESERVED'
    WHERE  m.run_id = p_run AND m.data_class = 'HIST'
    AND    m.partition_position = (SELECT MAX(x.partition_position) FROM pcopy_partition_map x
                                   WHERE x.run_id = p_run AND x.table_owner = m.table_owner AND x.table_name = m.table_name)
    AND    NOT EXISTS (SELECT 1 FROM pcopy_partition_map y
                       WHERE y.run_id = p_run AND y.table_owner = m.table_owner AND y.table_name = m.table_name
                       AND y.data_class = 'KEEP');
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'PRESERVE_LAST', SQL%ROWCOUNT || ' all-history tables keep their newest partition');

    -- Reference partitioned children follow the parent, by position. Loop for multi-level chains.
    LOOP
      UPDATE pcopy_partition_map c
      SET    (data_class, class_reason) = (
               SELECT p.data_class, 'REFERENCE_FROM_PARENT'
               FROM   dba_part_tables pt
               JOIN   dba_constraints fk ON fk.owner = pt.owner AND fk.constraint_name = pt.ref_ptn_constraint_name
               JOIN   dba_constraints pk ON pk.owner = fk.r_owner AND pk.constraint_name = fk.r_constraint_name
               JOIN   pcopy_partition_map p ON p.run_id = p_run AND p.table_owner = pk.owner AND p.table_name = pk.table_name
                                           AND p.partition_position = c.partition_position
               WHERE  pt.owner = c.table_owner AND pt.table_name = c.table_name)
      WHERE  c.run_id = p_run AND c.partitioning_type = 'REFERENCE'
      AND    c.class_reason IN ('REFERENCE_PENDING','REFERENCE_FROM_PARENT')
      AND    EXISTS (
               SELECT 1
               FROM   dba_part_tables pt
               JOIN   dba_constraints fk ON fk.owner = pt.owner AND fk.constraint_name = pt.ref_ptn_constraint_name
               JOIN   dba_constraints pk ON pk.owner = fk.r_owner AND pk.constraint_name = fk.r_constraint_name
               JOIN   pcopy_partition_map p ON p.run_id = p_run AND p.table_owner = pk.owner AND p.table_name = pk.table_name
                                           AND p.partition_position = c.partition_position
               WHERE  pt.owner = c.table_owner AND pt.table_name = c.table_name
               AND    (p.data_class <> c.data_class OR c.class_reason = 'REFERENCE_PENDING'));
      l_rows := SQL%ROWCOUNT;
      EXIT WHEN l_rows = 0;
    END LOOP;
    COMMIT;

    -- Tables whose HIST partitions cannot rely on offline cleanup on the target.
    IF pcopy_util.cfg('LOB_HIST_SKIP') <> 'Y' THEN
      UPDATE pcopy_partition_map m SET complex_reason = 'LOB'
      WHERE  m.run_id = p_run
      AND    EXISTS (SELECT 1 FROM dba_lobs l WHERE l.owner = m.table_owner AND l.table_name = m.table_name);
    END IF;
    UPDATE pcopy_partition_map m SET complex_reason = 'REFERENCE_PARTITIONING'
    WHERE  m.run_id = p_run AND m.complex_reason IS NULL
    AND   (m.partitioning_type = 'REFERENCE'
           OR EXISTS (SELECT 1 FROM dba_part_tables ch
                      JOIN dba_constraints fk ON fk.owner = ch.owner AND fk.constraint_name = ch.ref_ptn_constraint_name
                      JOIN dba_constraints pk ON pk.owner = fk.r_owner AND pk.constraint_name = fk.r_constraint_name
                      WHERE pk.owner = m.table_owner AND pk.table_name = m.table_name));
    UPDATE pcopy_partition_map m SET complex_reason = 'DOMAIN_OR_BITMAP_JOIN_INDEX'
    WHERE  m.run_id = p_run AND m.complex_reason IS NULL
    AND    EXISTS (SELECT 1 FROM dba_indexes i WHERE i.table_owner = m.table_owner AND i.table_name = m.table_name
                   AND (i.index_type = 'DOMAIN' OR i.join_index = 'YES'));
    UPDATE pcopy_partition_map m SET complex_reason = 'IOT_NESTED_OR_OBJECT'
    WHERE  m.run_id = p_run AND m.complex_reason IS NULL
    AND   (EXISTS (SELECT 1 FROM dba_tables t WHERE t.owner = m.table_owner AND t.table_name = m.table_name AND t.iot_type IS NOT NULL)
           OR EXISTS (SELECT 1 FROM dba_nested_tables n WHERE n.owner = m.table_owner AND n.parent_table_name = m.table_name)
           OR EXISTS (SELECT 1 FROM dba_object_tables o WHERE o.owner = m.table_owner AND o.table_name = m.table_name));
    COMMIT;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'CLASSIFY_PARTITIONS', l_n || ' partitions classified, cutoff '
                         || TO_CHAR(p_cutoff, 'YYYY-MM-DD'));
  END classify_partitions;

  PROCEDURE map_segments(p_run NUMBER) IS
  BEGIN
    -- Non-partitioned heap tables: always KEEP
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, segment_type, tablespace_name, gb, role, table_owner, table_name, data_class)
    SELECT p_run, t.owner, t.table_name, 'TABLE', t.tablespace_name, NVL(s.bytes,0)/c_gb, 'TABLE', t.owner, t.table_name, 'KEEP'
    FROM   dba_tables t
    JOIN   dba_users u ON u.username = t.owner AND u.oracle_maintained = 'N'
    LEFT JOIN pcopy_seg_snap s ON s.run_id = p_run AND s.owner = t.owner AND s.segment_name = t.table_name AND s.partition_name IS NULL
    WHERE  t.partitioned = 'NO' AND t.tablespace_name IS NOT NULL AND t.temporary = 'N' AND t.nested = 'NO'
    AND    t.iot_type IS NULL AND t.cluster_name IS NULL AND t.dropped = 'NO';

    -- Table partitions
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, seg_partition, segment_type, tablespace_name, gb, role, table_owner, table_name, table_partition, data_class)
    SELECT p_run, tp.table_owner, tp.table_name, tp.partition_name, 'TABLE PARTITION', tp.tablespace_name, NVL(s.bytes,0)/c_gb,
           'TABLE_PART', tp.table_owner, tp.table_name, tp.partition_name, m.data_class
    FROM   dba_tab_partitions tp
    JOIN   pcopy_partition_map m ON m.run_id = p_run AND m.table_owner = tp.table_owner AND m.table_name = tp.table_name AND m.partition_name = tp.partition_name
    LEFT JOIN pcopy_seg_snap s ON s.run_id = p_run AND s.owner = tp.table_owner AND s.segment_name = tp.table_name AND s.partition_name = tp.partition_name
    WHERE  tp.composite = 'NO';

    -- Table subpartitions
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, seg_partition, segment_type, tablespace_name, gb, role, table_owner, table_name, table_partition, table_subpartition, data_class)
    SELECT p_run, ts.table_owner, ts.table_name, ts.subpartition_name, 'TABLE SUBPARTITION', ts.tablespace_name, NVL(s.bytes,0)/c_gb,
           'TABLE_SUB', ts.table_owner, ts.table_name, ts.partition_name, ts.subpartition_name, m.data_class
    FROM   dba_tab_subpartitions ts
    JOIN   pcopy_partition_map m ON m.run_id = p_run AND m.table_owner = ts.table_owner AND m.table_name = ts.table_name AND m.partition_name = ts.partition_name
    LEFT JOIN pcopy_seg_snap s ON s.run_id = p_run AND s.owner = ts.table_owner AND s.segment_name = ts.table_name AND s.partition_name = ts.subpartition_name;

    -- Non-partitioned indexes. On a partitioned table they are global.
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, segment_type, tablespace_name, gb, role, table_owner, table_name, is_global, data_class)
    SELECT p_run, i.owner, i.index_name, 'INDEX', i.tablespace_name, NVL(s.bytes,0)/c_gb, 'INDEX', i.table_owner, i.table_name,
           CASE WHEN EXISTS (SELECT 1 FROM dba_part_tables pt WHERE pt.owner = i.table_owner AND pt.table_name = i.table_name) THEN 'Y' ELSE 'N' END, 'KEEP'
    FROM   dba_indexes i
    JOIN   dba_users u ON u.username = i.owner AND u.oracle_maintained = 'N'
    LEFT JOIN pcopy_seg_snap s ON s.run_id = p_run AND s.owner = i.owner AND s.segment_name = i.index_name AND s.partition_name IS NULL
    WHERE  i.partitioned = 'NO' AND i.index_type NOT IN ('LOB','IOT - TOP','DOMAIN','CLUSTER')
    AND    i.table_type = 'TABLE' AND i.dropped = 'NO' AND i.tablespace_name IS NOT NULL;

    -- Index partitions: LOCAL follows the table partition by position, GLOBAL is KEEP
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, seg_partition, segment_type, tablespace_name, gb, role, table_owner, table_name, table_partition, is_global, data_class)
    SELECT p_run, ip.index_owner, ip.index_name, ip.partition_name, 'INDEX PARTITION', ip.tablespace_name, NVL(s.bytes,0)/c_gb, 'INDEX_PART',
           i.table_owner, i.table_name, m.partition_name,
           CASE WHEN pi.locality = 'GLOBAL' THEN 'Y' ELSE 'N' END, NVL(m.data_class, 'KEEP')
    FROM   dba_ind_partitions ip
    JOIN   dba_part_indexes pi ON pi.owner = ip.index_owner AND pi.index_name = ip.index_name
    JOIN   dba_indexes i ON i.owner = ip.index_owner AND i.index_name = ip.index_name
    JOIN   dba_users u ON u.username = i.owner AND u.oracle_maintained = 'N'
    LEFT JOIN pcopy_partition_map m ON pi.locality = 'LOCAL' AND m.run_id = p_run AND m.table_owner = i.table_owner
                                   AND m.table_name = i.table_name AND m.partition_position = ip.partition_position
    LEFT JOIN pcopy_seg_snap s ON s.run_id = p_run AND s.owner = ip.index_owner AND s.segment_name = ip.index_name AND s.partition_name = ip.partition_name
    WHERE  ip.composite = 'NO' AND i.index_type NOT IN ('LOB','IOT - TOP','DOMAIN') AND i.dropped = 'NO';

    -- Local index subpartitions
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, seg_partition, segment_type, tablespace_name, gb, role, table_owner, table_name, table_partition, table_subpartition, data_class)
    SELECT p_run, isp.index_owner, isp.index_name, isp.subpartition_name, 'INDEX SUBPARTITION', isp.tablespace_name, NVL(s.bytes,0)/c_gb, 'INDEX_SUB',
           i.table_owner, i.table_name, m.partition_name, ts.subpartition_name, NVL(m.data_class, 'KEEP')
    FROM   dba_ind_subpartitions isp
    JOIN   dba_ind_partitions ip ON ip.index_owner = isp.index_owner AND ip.index_name = isp.index_name AND ip.partition_name = isp.partition_name
    JOIN   dba_indexes i ON i.owner = isp.index_owner AND i.index_name = isp.index_name
    JOIN   dba_users u ON u.username = i.owner AND u.oracle_maintained = 'N'
    LEFT JOIN pcopy_partition_map m ON m.run_id = p_run AND m.table_owner = i.table_owner AND m.table_name = i.table_name
                                   AND m.partition_position = ip.partition_position
    LEFT JOIN dba_tab_subpartitions ts ON ts.table_owner = i.table_owner AND ts.table_name = i.table_name
                                      AND ts.partition_name = m.partition_name AND ts.subpartition_position = isp.subpartition_position
    LEFT JOIN pcopy_seg_snap s ON s.run_id = p_run AND s.owner = isp.index_owner AND s.segment_name = isp.index_name AND s.partition_name = isp.subpartition_name
    WHERE  i.index_type NOT IN ('LOB','IOT - TOP','DOMAIN') AND i.dropped = 'NO';

    -- LOB segments of non-partitioned tables
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, segment_type, tablespace_name, gb, role, table_owner, table_name, lob_column, data_class)
    SELECT p_run, l.owner, l.segment_name, 'LOBSEGMENT', l.tablespace_name, NVL(s.bytes,0)/c_gb, 'LOB', l.owner, l.table_name, l.column_name, 'KEEP'
    FROM   dba_lobs l
    JOIN   dba_users u ON u.username = l.owner AND u.oracle_maintained = 'N'
    LEFT JOIN pcopy_seg_snap s ON s.run_id = p_run AND s.owner = l.owner AND s.segment_name = l.segment_name AND s.partition_name IS NULL
    WHERE  l.partitioned = 'NO' AND l.table_name NOT LIKE 'BIN$%';

    -- LOB partitions
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, seg_partition, segment_type, tablespace_name, gb, role, table_owner, table_name, table_partition, lob_column, data_class)
    SELECT p_run, lp.table_owner, lp.lob_name, lp.lob_partition_name, 'LOB PARTITION', lp.tablespace_name, NVL(s.bytes,0)/c_gb, 'LOB_PART',
           lp.table_owner, lp.table_name, lp.partition_name, lp.column_name, m.data_class
    FROM   dba_lob_partitions lp
    JOIN   pcopy_partition_map m ON m.run_id = p_run AND m.table_owner = lp.table_owner AND m.table_name = lp.table_name AND m.partition_name = lp.partition_name
    LEFT JOIN pcopy_seg_snap s ON s.run_id = p_run AND s.owner = lp.table_owner AND s.segment_name = lp.lob_name AND s.partition_name = lp.lob_partition_name
    WHERE  lp.composite = 'NO';

    -- LOB subpartitions
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, seg_partition, segment_type, tablespace_name, gb, role, table_owner, table_name, table_partition, table_subpartition, lob_column, data_class)
    SELECT p_run, ls.table_owner, ls.lob_name, ls.lob_subpartition_name, 'LOB SUBPARTITION', ls.tablespace_name, NVL(s.bytes,0)/c_gb, 'LOB_SUB',
           ls.table_owner, ls.table_name, lp.partition_name, ls.subpartition_name, ls.column_name, m.data_class
    FROM   dba_lob_subpartitions ls
    JOIN   dba_lob_partitions lp ON lp.table_owner = ls.table_owner AND lp.table_name = ls.table_name
                                AND lp.column_name = ls.column_name AND lp.lob_partition_name = ls.lob_partition_name
    JOIN   pcopy_partition_map m ON m.run_id = p_run AND m.table_owner = ls.table_owner AND m.table_name = ls.table_name AND m.partition_name = lp.partition_name
    LEFT JOIN pcopy_seg_snap s ON s.run_id = p_run AND s.owner = ls.table_owner AND s.segment_name = ls.lob_name AND s.partition_name = ls.lob_subpartition_name;

    -- LOB index segments travel with their LOB: mapped for sizing and class, never moved by themselves.
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, seg_partition, segment_type, tablespace_name, gb, role, table_owner, table_name, table_partition, table_subpartition, lob_column, data_class)
    SELECT p_run, s.owner, s.segment_name, s.partition_name, s.segment_type, s.tablespace_name, s.bytes/c_gb, 'LOBINDEX',
           l.owner, l.table_name, x.partition_name, x.subpartition_name, l.column_name, NVL(m.data_class, 'KEEP')
    FROM   dba_lobs l
    JOIN   dba_users u ON u.username = l.owner AND u.oracle_maintained = 'N'
    JOIN   pcopy_seg_snap s ON s.run_id = p_run AND s.owner = l.owner AND s.segment_name = l.index_name
    LEFT JOIN (SELECT table_owner, table_name, column_name, lob_indpart_name ind_part, partition_name, CAST(NULL AS VARCHAR2(128)) subpartition_name
               FROM   dba_lob_partitions
               UNION ALL
               SELECT ls.table_owner, ls.table_name, ls.column_name, ls.lob_indsubpart_name, lp.partition_name, ls.subpartition_name
               FROM   dba_lob_subpartitions ls
               JOIN   dba_lob_partitions lp ON lp.table_owner = ls.table_owner AND lp.table_name = ls.table_name
                                           AND lp.column_name = ls.column_name AND lp.lob_partition_name = ls.lob_partition_name) x
           ON x.table_owner = l.owner AND x.table_name = l.table_name AND x.column_name = l.column_name AND x.ind_part = s.partition_name
    LEFT JOIN pcopy_partition_map m ON m.run_id = p_run AND m.table_owner = l.owner AND m.table_name = l.table_name AND m.partition_name = x.partition_name;

    -- Whatever is left (IOT, overflow, nested, clusters, domain secondary objects, SYS objects...) cannot be
    -- moved automatically. The mapping stays conservative: class KEEP, role OTHER.
    INSERT INTO pcopy_segment_map (run_id, seg_owner, seg_name, seg_partition, segment_type, tablespace_name, gb, role, table_owner, data_class)
    SELECT p_run, s.owner, s.segment_name, s.partition_name, s.segment_type, s.tablespace_name, s.bytes/c_gb, 'OTHER', s.owner, 'KEEP'
    FROM   pcopy_seg_snap s
    WHERE  s.run_id = p_run
    AND    s.segment_name NOT LIKE 'BIN$%'
    AND    NOT EXISTS (SELECT 1 FROM pcopy_segment_map m
                       WHERE m.run_id = p_run AND m.seg_owner = s.owner AND m.seg_name = s.segment_name
                       AND   NVL(m.seg_partition,'~') = NVL(s.partition_name,'~'));
    COMMIT;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'MAP_SEGMENTS', 'Mapping complete');
  END map_segments;

  PROCEDURE map_tablespaces(p_run NUMBER) IS
    l_min   NUMBER := pcopy_util.cfg_num('MIN_SAVING_GB');
    l_def   VARCHAR2(128);
    l_dec   VARCHAR2(14); l_act VARCHAR2(15); l_why VARCHAR2(400); l_movable NUMBER;
  BEGIN
    SELECT property_value INTO l_def FROM database_properties WHERE property_name = 'DEFAULT_PERMANENT_TABLESPACE';

    INSERT INTO pcopy_ts_map (run_id, tablespace_name, contents, status, block_size, ssm, encrypted, bigfile,
                              alloc_gb, max_gb, used_gb, hist_gb, keep_gb, hist_lob_gb, keep_lob_gb,
                              hist_units, keep_units, unmovable_units, complex_hist_units, complex_hist_gb)
    SELECT p_run, t.tablespace_name, t.contents, t.status, t.block_size, t.segment_space_management, t.encrypted, t.bigfile,
           f.alloc_gb, f.max_gb, NVL(u.used_gb,0),
           NVL(a.hist_gb,0), NVL(a.keep_gb,0), NVL(a.hist_lob_gb,0), NVL(a.keep_lob_gb,0),
           NVL(a.hist_units,0), NVL(a.keep_units,0), NVL(a.unmovable,0), NVL(cx.units,0), NVL(cx.gb,0)
    FROM   dba_tablespaces t
    LEFT JOIN (SELECT tablespace_name, SUM(bytes)/c_gb alloc_gb, SUM(GREATEST(bytes, maxbytes))/c_gb max_gb
               FROM dba_data_files GROUP BY tablespace_name) f ON f.tablespace_name = t.tablespace_name
    LEFT JOIN (SELECT tablespace_name, SUM(bytes)/c_gb used_gb FROM pcopy_seg_snap WHERE run_id = p_run
               GROUP BY tablespace_name) u ON u.tablespace_name = t.tablespace_name
    LEFT JOIN (SELECT tablespace_name,
                      SUM(CASE WHEN data_class='HIST' THEN gb ELSE 0 END) hist_gb,
                      SUM(CASE WHEN data_class='KEEP' THEN gb ELSE 0 END) keep_gb,
                      SUM(CASE WHEN data_class='HIST' AND role LIKE 'LOB%' THEN gb ELSE 0 END) hist_lob_gb,
                      SUM(CASE WHEN data_class='KEEP' AND role LIKE 'LOB%' THEN gb ELSE 0 END) keep_lob_gb,
                      COUNT(CASE WHEN data_class='HIST' THEN 1 END) hist_units,
                      COUNT(CASE WHEN data_class='KEEP' AND role <> 'LOBINDEX' THEN 1 END) keep_units,
                      COUNT(CASE WHEN role='OTHER' THEN 1 END) unmovable
               FROM pcopy_segment_map WHERE run_id = p_run GROUP BY tablespace_name) a ON a.tablespace_name = t.tablespace_name
    LEFT JOIN (SELECT s.tablespace_name, COUNT(*) units, SUM(s.gb) gb
               FROM   pcopy_segment_map s
               JOIN   pcopy_partition_map m ON m.run_id = s.run_id AND m.table_owner = s.table_owner
                                           AND m.table_name = s.table_name AND m.partition_name = s.table_partition
               WHERE  s.run_id = p_run AND s.data_class = 'HIST' AND m.complex_reason IS NOT NULL
               GROUP  BY s.tablespace_name) cx ON cx.tablespace_name = t.tablespace_name;

    FOR r IN (SELECT * FROM pcopy_ts_map WHERE run_id = p_run) LOOP
      l_act := 'NONE';
      l_movable := r.hist_gb - r.complex_hist_gb;

      IF r.contents <> 'PERMANENT' OR r.tablespace_name IN ('SYSTEM','SYSAUX','PCOPY_TS') OR r.tablespace_name = l_def THEN
        UPDATE pcopy_ts_map SET classification = 'SYSTEM', decision = 'RESTORE', action = 'NONE',
               decision_reason = 'System, undo, temp, database default or PCOPY tablespace'
        WHERE  run_id = p_run AND tablespace_name = r.tablespace_name;
        CONTINUE;
      END IF;

      -- Tablespace with history whose cleanup needs it online (LOB, reference...) is restored, then emptied.
      IF r.hist_units = 0 AND r.keep_units = 0 THEN
        UPDATE pcopy_ts_map SET classification = 'EMPTY', decision = 'RESTORE', action = 'NONE',
               decision_reason = 'Empty'
        WHERE  run_id = p_run AND tablespace_name = r.tablespace_name;
        CONTINUE;
      ELSIF r.hist_units = 0 THEN
        UPDATE pcopy_ts_map SET classification = 'PURE_KEEP', decision = 'RESTORE', action = 'NONE',
               decision_reason = 'Only recent data or full tables'
        WHERE  run_id = p_run AND tablespace_name = r.tablespace_name;
        CONTINUE;
      END IF;

      IF r.keep_units = 0 THEN
        IF r.complex_hist_units = 0 THEN
          l_dec := 'SKIP'; l_why := 'Only history. Not restored';
        ELSIF l_movable >= l_min THEN
          l_dec := 'RESTORE_DROP'; l_act := 'MOVE_HIST_OUT';
          l_why := 'Mixes ' || ROUND(r.complex_hist_gb) || ' GB history needing online cleanup with '
                || ROUND(l_movable) || ' GB plain history: move the plain history to a skipped tablespace';
        ELSE
          l_dec := 'RESTORE_DROP';
          l_why := 'History needs online cleanup (see complex_reason). Restored, then partitions dropped on target';
        END IF;
        UPDATE pcopy_ts_map SET classification = 'PURE_HIST', decision = l_dec, action = l_act, decision_reason = l_why
        WHERE  run_id = p_run AND tablespace_name = r.tablespace_name;
        CONTINUE;
      END IF;

      -- MIXED: move as little as possible
      IF r.hist_gb < l_min THEN
        l_dec := 'RESTORE'; l_act := 'LEAVE';
        l_why := 'Only ' || ROUND(r.hist_gb) || ' GB history, below MIN_SAVING_GB: leave, drop partitions on target';
      ELSIF r.complex_hist_units > 0 THEN
        l_dec := 'RESTORE';
        IF l_movable >= l_min THEN
          l_act := 'MOVE_HIST_OUT';
          l_why := 'Contains history needing online cleanup, so it stays restored. Move ' || ROUND(l_movable) || ' GB plain history out';
        ELSE
          l_act := 'LEAVE';
          l_why := 'History needs online cleanup. Leave, drop partitions on target';
        END IF;
      ELSIF r.unmovable_units > 0 THEN
        l_dec := 'RESTORE'; l_act := 'MOVE_HIST_OUT';
        l_why := 'Holds objects that cannot be moved automatically: move ' || ROUND(r.hist_gb) || ' GB history out';
      ELSIF r.keep_gb <= r.hist_gb THEN
        l_dec := 'SKIP'; l_act := 'MOVE_KEEP_OUT';
        l_why := 'Move ' || ROUND(r.keep_gb) || ' GB recent data out, saves ' || ROUND(r.hist_gb) || ' GB';
      ELSE
        l_dec := 'RESTORE'; l_act := 'MOVE_HIST_OUT';
        l_why := 'Move ' || ROUND(r.hist_gb) || ' GB history out (smaller than ' || ROUND(r.keep_gb) || ' GB recent data)';
      END IF;
      UPDATE pcopy_ts_map SET classification = 'MIXED', decision = l_dec, action = l_act, decision_reason = l_why
      WHERE  run_id = p_run AND tablespace_name = r.tablespace_name;
    END LOOP;
    COMMIT;
    pcopy_util.write_log(p_run, 'INFO', c_mod, 'MAP_TABLESPACES', 'Tablespace decisions complete');
  END map_tablespaces;

  FUNCTION run_mapping(p_note VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    l_cutoff DATE := get_cutoff;
    l_run    NUMBER := pcopy_util.new_run('MAPPING', l_cutoff, p_note);
    l_scn    NUMBER;
  BEGIN
    pcopy_util.write_log(l_run, 'INFO', c_mod, 'START', 'Mapping started, cutoff ' || TO_CHAR(l_cutoff, 'YYYY-MM-DD'));
    snap_segments(l_run);
    classify_partitions(l_run, l_cutoff);
    map_segments(l_run);
    map_tablespaces(l_run);
    SELECT current_scn INTO l_scn FROM v$database;
    UPDATE pcopy_run SET map_scn = l_scn WHERE run_id = l_run;
    COMMIT;
    pcopy_util.end_run(l_run, 'MAPPED');
    RETURN l_run;
  EXCEPTION WHEN OTHERS THEN
    pcopy_util.log_error(l_run, c_mod, 'RUN_MAPPING');
    pcopy_util.end_run(l_run, 'FAILED');
    ROLLBACK;
    RAISE;
  END run_mapping;

  PROCEDURE set_ts_decision(p_run NUMBER, p_ts VARCHAR2, p_decision VARCHAR2, p_action VARCHAR2, p_reason VARCHAR2) IS
  BEGIN
    IF p_decision NOT IN ('SKIP','RESTORE','RESTORE_DROP') OR p_action NOT IN ('NONE','LEAVE','MOVE_KEEP_OUT','MOVE_HIST_OUT') THEN
      RAISE_APPLICATION_ERROR(-20101, 'Invalid decision or action');
    END IF;
    UPDATE pcopy_ts_map SET decision = p_decision, action = p_action, is_override = 'Y',
           decision_reason = 'OVERRIDE: ' || p_reason
    WHERE  run_id = p_run AND tablespace_name = p_ts AND classification <> 'SYSTEM';
    IF SQL%ROWCOUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20102, 'Tablespace not found, or a system tablespace: ' || p_ts);
    END IF;
    COMMIT;
    pcopy_util.write_log(p_run, 'WARN', c_mod, 'OVERRIDE', p_decision || '/' || p_action || ': ' || p_reason, p_ts => p_ts);
  END set_ts_decision;

END pcopy_map;
/
SHOW ERRORS

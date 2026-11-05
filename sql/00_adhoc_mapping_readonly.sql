-- =============================================================================
-- 00_adhoc_mapping_readonly.sql
-- Zero-footprint, READ-ONLY mapping queries. Installs nothing. Safe on production,
-- but the DBA_SEGMENTS based queries are heavy: run them off-peak.
-- Requires: 19c (WITH FUNCTION, LISTAGG DISTINCT, BANNER_FULL), SELECT ANY DICTIONARY.
-- Usage: sqlplus / as sysdba @00_adhoc_mapping_readonly.sql 2024-11-01
--        (argument = cutoff date; a partition is HIST when HIGH_VALUE <= cutoff)
-- Partition keys that are not DATE/TIMESTAMP are reported as UNKNOWN and counted as KEEP
-- here. The installed PCOPY_MAP package resolves them through PCOPY_TABLE_RULE.
-- =============================================================================
SET LINESIZE 260 PAGESIZE 5000 TRIMSPOOL ON TAB OFF VERIFY OFF FEEDBACK ON
DEFINE CUTOFF = &1
SPOOL adhoc_mapping_&&CUTOFF..log

COLUMN tablespace_name FORMAT A30
COLUMN owner           FORMAT A20
COLUMN table_owner     FORMAT A20
COLUMN table_name      FORMAT A32
COLUMN index_name      FORMAT A32
COLUMN partition_name  FORMAT A28
COLUMN column_name     FORMAT A28
COLUMN detail          FORMAT A70

PROMPT ===== Q01  Database size by tablespace type =====
SELECT t.contents, t.status, COUNT(DISTINCT t.tablespace_name) ts_count,
       ROUND(SUM(f.bytes)/POWER(1024,4),2) alloc_tb
FROM   dba_tablespaces t JOIN dba_data_files f ON f.tablespace_name = t.tablespace_name
GROUP  BY t.contents, t.status ORDER BY 4 DESC;

PROMPT ===== Q02  Tablespace classification: HIST vs KEEP (heart of the analysis) =====
SET SQLTERMINATOR OFF
WITH
  FUNCTION hv_date(p_o VARCHAR2, p_t VARCHAR2, p_p VARCHAR2) RETURN DATE IS
    l_long LONG; l_d DATE;
  BEGIN
    SELECT high_value INTO l_long FROM dba_tab_partitions
     WHERE table_owner = p_o AND table_name = p_t AND partition_name = p_p;
    EXECUTE IMMEDIATE 'SELECT CAST(' || l_long || ' AS DATE) FROM dual' INTO l_d;
    RETURN l_d;
  EXCEPTION WHEN OTHERS THEN RETURN NULL;  -- MAXVALUE, NUMBER/VARCHAR key, multi-column
  END;
cls AS (
  SELECT /*+ MATERIALIZE */ tp.table_owner, tp.table_name, tp.partition_name, tp.partition_position,
         CASE WHEN hv_date(tp.table_owner, tp.table_name, tp.partition_name) <= DATE '&&CUTOFF'
              THEN 'HIST' ELSE 'KEEP' END data_class
  FROM   dba_tab_partitions tp
  JOIN   dba_users u ON u.username = tp.table_owner AND u.oracle_maintained = 'N'
),
seg AS (
  SELECT /*+ MATERIALIZE */ owner, segment_name, partition_name, segment_type, tablespace_name, bytes
  FROM   dba_segments
),
r AS (
  -- table partitions
  SELECT c.data_class, 'TAB' kind, s.tablespace_name, s.bytes
  FROM   cls c JOIN seg s ON s.owner = c.table_owner AND s.segment_name = c.table_name
                         AND s.partition_name = c.partition_name
  UNION ALL
  -- table subpartitions
  SELECT c.data_class, 'TAB', s.tablespace_name, s.bytes
  FROM   cls c
  JOIN   dba_tab_subpartitions ts ON ts.table_owner = c.table_owner AND ts.table_name = c.table_name
                                 AND ts.partition_name = c.partition_name
  JOIN   seg s ON s.owner = ts.table_owner AND s.segment_name = ts.table_name
              AND s.partition_name = ts.subpartition_name
  UNION ALL
  -- local index partitions (class follows the table partition, global = KEEP)
  SELECT NVL(c.data_class,'KEEP'), 'IDX', s.tablespace_name, s.bytes
  FROM   dba_ind_partitions ip
  JOIN   dba_part_indexes pi ON pi.owner = ip.index_owner AND pi.index_name = ip.index_name
  JOIN   dba_indexes i ON i.owner = ip.index_owner AND i.index_name = ip.index_name
  JOIN   seg s ON s.owner = ip.index_owner AND s.segment_name = ip.index_name
              AND s.partition_name = ip.partition_name
  LEFT JOIN cls c ON pi.locality = 'LOCAL' AND c.table_owner = i.table_owner
                 AND c.table_name = i.table_name AND c.partition_position = ip.partition_position
  UNION ALL
  -- LOB partitions
  SELECT c.data_class, 'LOB', s.tablespace_name, s.bytes
  FROM   dba_lob_partitions lp
  JOIN   cls c ON c.table_owner = lp.table_owner AND c.table_name = lp.table_name
              AND c.partition_name = lp.partition_name
  JOIN   seg s ON s.owner = lp.table_owner AND s.segment_name = lp.lob_name
              AND s.partition_name = lp.lob_partition_name
  UNION ALL
  -- LOB subpartitions
  SELECT c.data_class, 'LOB', s.tablespace_name, s.bytes
  FROM   dba_lob_subpartitions ls
  JOIN   dba_lob_partitions lp ON lp.table_owner = ls.table_owner AND lp.table_name = ls.table_name
                              AND lp.column_name = ls.column_name
                              AND lp.lob_partition_name = ls.lob_partition_name
  JOIN   cls c ON c.table_owner = lp.table_owner AND c.table_name = lp.table_name
              AND c.partition_name = lp.partition_name
  JOIN   seg s ON s.owner = ls.table_owner AND s.segment_name = ls.lob_name
              AND s.partition_name = ls.lob_subpartition_name
  UNION ALL
  -- everything non-partitioned must come in full
  SELECT 'KEEP', 'NONPART', s.tablespace_name, s.bytes
  FROM   seg s WHERE s.segment_type NOT LIKE '%PARTITION'
)
SELECT t.tablespace_name, t.status,
       ROUND(SUM(CASE WHEN r.data_class='HIST' THEN r.bytes END)/POWER(1024,3),1) hist_gb,
       ROUND(SUM(CASE WHEN r.data_class='KEEP' THEN r.bytes END)/POWER(1024,3),1) keep_gb,
       ROUND(SUM(CASE WHEN r.kind='LOB' AND r.data_class='HIST' THEN r.bytes END)/POWER(1024,3),1) hist_lob_gb,
       ROUND(SUM(CASE WHEN r.kind='LOB' AND r.data_class='KEEP' THEN r.bytes END)/POWER(1024,3),1) keep_lob_gb,
       CASE WHEN SUM(CASE WHEN r.data_class='KEEP' THEN r.bytes ELSE 0 END)=0
             AND SUM(CASE WHEN r.data_class='HIST' THEN r.bytes ELSE 0 END)>0 THEN 'PURE_HIST'
            WHEN SUM(CASE WHEN r.data_class='HIST' THEN r.bytes ELSE 0 END)=0 THEN 'PURE_KEEP'
            ELSE 'MIXED' END classification
FROM   dba_tablespaces t LEFT JOIN r ON r.tablespace_name = t.tablespace_name
WHERE  t.contents = 'PERMANENT'
GROUP  BY t.tablespace_name, t.status
ORDER  BY 3 DESC NULLS LAST
/
SET SQLTERMINATOR ON

PROMPT ===== Q03  Read-only tablespaces holding partitions NEWER than the cutoff =====
SET SQLTERMINATOR OFF
WITH
  FUNCTION hv_date(p_o VARCHAR2, p_t VARCHAR2, p_p VARCHAR2) RETURN DATE IS
    l_long LONG; l_d DATE;
  BEGIN
    SELECT high_value INTO l_long FROM dba_tab_partitions
     WHERE table_owner = p_o AND table_name = p_t AND partition_name = p_p;
    EXECUTE IMMEDIATE 'SELECT CAST(' || l_long || ' AS DATE) FROM dual' INTO l_d;
    RETURN l_d;
  EXCEPTION WHEN OTHERS THEN RETURN NULL;
  END;
SELECT tp.tablespace_name, tp.table_owner, tp.table_name, tp.partition_name,
       hv_date(tp.table_owner, tp.table_name, tp.partition_name) high_value_dt
FROM   dba_tab_partitions tp
JOIN   dba_tablespaces t ON t.tablespace_name = tp.tablespace_name AND t.status = 'READ ONLY'
WHERE  NVL(hv_date(tp.table_owner, tp.table_name, tp.partition_name), DATE '9999-12-31') > DATE '&&CUTOFF'
ORDER  BY 1,2,3,5
/
SET SQLTERMINATOR ON

PROMPT ===== Q04  Partitioned tables whose key cannot be evaluated as a date (need PCOPY_TABLE_RULE) =====
SELECT pt.owner, pt.table_name, pt.partitioning_type, pt.subpartitioning_type, pt.partition_count,
       pt.partitioning_key_count key_cols, tc.data_type key_type, kc.column_name
FROM   dba_part_tables pt
JOIN   dba_users u ON u.username = pt.owner AND u.oracle_maintained = 'N'
LEFT JOIN dba_part_key_columns kc ON kc.owner = pt.owner AND kc.name = pt.table_name
                                 AND TRIM(kc.object_type) = 'TABLE' AND kc.column_position = 1
LEFT JOIN dba_tab_cols tc ON tc.owner = kc.owner AND tc.table_name = kc.name AND tc.column_name = kc.column_name
WHERE  pt.table_name NOT LIKE 'BIN$%'
AND    (pt.partitioning_type <> 'RANGE' OR pt.partitioning_key_count > 1
        OR (tc.data_type <> 'DATE' AND tc.data_type NOT LIKE 'TIMESTAMP%'))
ORDER  BY pt.partition_count DESC;

PROMPT ===== Q05  LOB inventory: type, attributes, size =====
SELECT l.owner, l.table_name, l.column_name, l.partitioned, l.securefile, l.in_row, l.compression,
       l.deduplication, l.encrypt, l.logging, l.cache, l.tablespace_name def_or_ts,
       ROUND(SUM(s.bytes)/POWER(1024,3),1) gb
FROM   dba_lobs l
JOIN   dba_users u ON u.username = l.owner AND u.oracle_maintained = 'N'
LEFT JOIN dba_segments s ON s.owner = l.owner AND s.segment_name = l.segment_name
GROUP  BY l.owner, l.table_name, l.column_name, l.partitioned, l.securefile, l.in_row, l.compression,
          l.deduplication, l.encrypt, l.logging, l.cache, l.tablespace_name
ORDER  BY gb DESC NULLS LAST;

PROMPT ===== Q06  LOB partitions stored in a different tablespace than their table partition =====
SELECT lp.table_owner, lp.table_name, lp.column_name, lp.partition_name,
       tp.tablespace_name table_ts, lp.tablespace_name lob_ts
FROM   dba_lob_partitions lp
JOIN   dba_tab_partitions tp ON tp.table_owner = lp.table_owner AND tp.table_name = lp.table_name
                            AND tp.partition_name = lp.partition_name
WHERE  lp.composite = 'NO' AND tp.tablespace_name <> lp.tablespace_name
ORDER  BY 1,2,3,4;

PROMPT ===== Q07  Local index partitions stored in a different tablespace than their table partition =====
SELECT i.table_owner, i.table_name, ip.index_name, ip.partition_name,
       tp.tablespace_name table_ts, ip.tablespace_name index_ts
FROM   dba_ind_partitions ip
JOIN   dba_part_indexes pi ON pi.owner = ip.index_owner AND pi.index_name = ip.index_name AND pi.locality = 'LOCAL'
JOIN   dba_indexes i ON i.owner = ip.index_owner AND i.index_name = ip.index_name AND i.index_type <> 'LOB'
JOIN   dba_tab_partitions tp ON tp.table_owner = i.table_owner AND tp.table_name = i.table_name
                            AND tp.partition_position = ip.partition_position
WHERE  ip.composite = 'NO' AND tp.tablespace_name <> ip.tablespace_name
ORDER  BY 1,2,3,4;

PROMPT ===== Q08  Global indexes on partitioned tables (must stay restored, need rebuild on target) =====
SELECT i.table_owner, i.table_name, i.index_name, i.partitioned, i.uniqueness, i.status,
       ROUND(SUM(s.bytes)/POWER(1024,3),1) gb, LISTAGG(DISTINCT s.tablespace_name, ',') WITHIN GROUP (ORDER BY s.tablespace_name) ts_list
FROM   dba_indexes i
JOIN   dba_part_tables pt ON pt.owner = i.table_owner AND pt.table_name = i.table_name
LEFT JOIN dba_part_indexes pi ON pi.owner = i.owner AND pi.index_name = i.index_name
LEFT JOIN dba_segments s ON s.owner = i.owner AND s.segment_name = i.index_name
WHERE  i.index_type NOT IN ('LOB','IOT - TOP','DOMAIN')
AND    (i.partitioned = 'NO' OR pi.locality = 'GLOBAL')
GROUP  BY i.table_owner, i.table_name, i.index_name, i.partitioned, i.uniqueness, i.status
ORDER  BY gb DESC NULLS LAST;

PROMPT ===== Q09  Default attributes (where FUTURE partitions land) =====
SELECT 'TABLE' src, owner, table_name obj, NULL col, def_tablespace_name def_ts, interval
FROM   dba_part_tables WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL
SELECT 'INDEX', owner, index_name, NULL, def_tablespace_name, interval
FROM   dba_part_indexes WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL
SELECT 'LOB', table_owner, table_name, column_name, def_tablespace_name, NULL
FROM   dba_part_lobs WHERE table_owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
ORDER  BY 5,2,3;

PROMPT ===== Q10  Foreign keys into partitioned tables =====
SELECT c.owner child_owner, c.table_name child_table, c.constraint_name fk_name, c.status, c.validated,
       p.owner parent_owner, p.table_name parent_table,
       (SELECT partitioning_type FROM dba_part_tables x WHERE x.owner = c.owner AND x.table_name = c.table_name) child_part_type
FROM   dba_constraints c
JOIN   dba_constraints p ON p.owner = c.r_owner AND p.constraint_name = c.r_constraint_name
JOIN   dba_part_tables pt ON pt.owner = p.owner AND pt.table_name = p.table_name
WHERE  c.constraint_type = 'R' AND c.owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
ORDER  BY 6,7,1,2;

PROMPT ===== Q11  Objects that need special handling =====
SELECT 'IOT' kind, owner, table_name obj, iot_type detail FROM dba_tables
 WHERE iot_type IS NOT NULL AND owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL SELECT 'NESTED', owner, table_name, parent_table_name FROM dba_nested_tables
 WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL SELECT 'XMLTYPE', owner, table_name, column_name||' / '||storage_type FROM dba_xml_tab_cols
 WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL SELECT 'DOMAIN_INDEX', owner, index_name, ityp_owner||'.'||ityp_name||' on '||table_name FROM dba_indexes
 WHERE index_type = 'DOMAIN' AND owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL SELECT 'BITMAP_JOIN_INDEX', owner, index_name, table_name FROM dba_indexes
 WHERE join_index = 'YES' AND owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL SELECT 'MVIEW', owner, mview_name, container_name FROM dba_mviews
 WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL SELECT 'MV_LOG', log_owner, master, log_table FROM dba_mview_logs
 WHERE log_owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL SELECT 'QUEUE_TABLE', owner, queue_table, object_type FROM dba_queue_tables
 WHERE owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL SELECT 'LONG_COLUMN', owner, table_name, column_name FROM dba_tab_cols
 WHERE data_type IN ('LONG','LONG RAW') AND owner IN (SELECT username FROM dba_users WHERE oracle_maintained='N')
UNION ALL SELECT 'REFERENCE_PART', owner, table_name, ref_ptn_constraint_name FROM dba_part_tables
 WHERE partitioning_type = 'REFERENCE'
UNION ALL SELECT 'HCC', table_owner, table_name, COUNT(*)||' partitions '||compress_for FROM dba_tab_partitions
 WHERE compress_for LIKE 'QUERY%' OR compress_for LIKE 'ARCHIVE%' GROUP BY table_owner, table_name, compress_for
ORDER BY 1,2,3;

PROMPT ===== Q12  Tablespace attributes relevant for moves and restore =====
SELECT tablespace_name, status, block_size, bigfile, segment_space_management ssm, encrypted, logging, force_logging, compress_for
FROM   dba_tablespaces WHERE contents = 'PERMANENT' ORDER BY 1;

PROMPT ===== Q13  Database context =====
SELECT name, db_unique_name, cdb, log_mode, force_logging, flashback_on, database_role, open_mode FROM v$database;
SELECT banner_full FROM v$version;
SELECT status FROM v$block_change_tracking;

PROMPT ===== Q14  Recycle bin content (purge before the final check) =====
SELECT ts_name tablespace_name, owner, COUNT(*) objects, ROUND(SUM(space*8192)/POWER(1024,3),1) approx_gb_at_8k
FROM   dba_recyclebin GROUP BY ts_name, owner ORDER BY 4 DESC NULLS LAST;

SPOOL OFF

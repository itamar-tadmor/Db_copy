-- =============================================================================
-- poc_offline_cleanup.sql  -  GATE 0. Run on a TEST database only, same version and
-- patch level as production. Answers what the design cannot take from documentation:
--   * what happens to partitions in an offline tablespace, per table shape
--   * whether LOB tables can be cleaned while the tablespace is offline
--   * whether the exact MOVE / REBUILD / DEFAULT ATTRIBUTES statements of the plan parse and work
--
-- Usage:  sqlplus / as sysdba @poc_offline_cleanup.sql <TEST_DB_NAME>
-- Guard: stops unless <TEST_DB_NAME> equals v$database.name.
-- Creates tablespaces POC_K, POC_K2, POC_H and user POC, and drops them at the next run. Needs OMF.
-- Result: POC.POC_RESULT. Send that output back to finalize LOB_HIST_SKIP and p_method.
-- =============================================================================
SET SERVEROUTPUT ON SIZE UNLIMITED LINESIZE 220 PAGESIZE 200 VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE

DECLARE l VARCHAR2(30);
BEGIN
  SELECT name INTO l FROM v$database;
  IF l <> UPPER('&1') THEN
    RAISE_APPLICATION_ERROR(-20001, 'Connected to ' || l || ', not &1. Stopping.');
  END IF;
END;
/
WHENEVER SQLERROR CONTINUE

-- Clean previous attempts
DROP USER poc CASCADE;
DROP TABLESPACE poc_h  INCLUDING CONTENTS AND DATAFILES CASCADE CONSTRAINTS;
DROP TABLESPACE poc_k2 INCLUDING CONTENTS AND DATAFILES CASCADE CONSTRAINTS;
DROP TABLESPACE poc_k  INCLUDING CONTENTS AND DATAFILES CASCADE CONSTRAINTS;

WHENEVER SQLERROR EXIT FAILURE
CREATE TABLESPACE poc_k  DATAFILE SIZE 200M AUTOEXTEND ON SEGMENT SPACE MANAGEMENT AUTO;
CREATE TABLESPACE poc_k2 DATAFILE SIZE 200M AUTOEXTEND ON SEGMENT SPACE MANAGEMENT AUTO;
CREATE TABLESPACE poc_h  DATAFILE SIZE 200M AUTOEXTEND ON SEGMENT SPACE MANAGEMENT AUTO;
-- Schema-only account: nobody can log in to it.
CREATE USER poc NO AUTHENTICATION DEFAULT TABLESPACE poc_k
  QUOTA UNLIMITED ON poc_k QUOTA UNLIMITED ON poc_k2 QUOTA UNLIMITED ON poc_h;

CREATE TABLE poc.poc_result (
  seq NUMBER GENERATED ALWAYS AS IDENTITY, scenario VARCHAR2(20), test_name VARCHAR2(40),
  outcome VARCHAR2(5), ora VARCHAR2(200), stmt VARCHAR2(400)
) TABLESPACE poc_k;
WHENEVER SQLERROR CONTINUE

CREATE OR REPLACE PROCEDURE poc.t(p_scn VARCHAR2, p_test VARCHAR2, p_sql VARCHAR2) AUTHID DEFINER IS
  PRAGMA AUTONOMOUS_TRANSACTION;
  l_err VARCHAR2(200);
BEGIN
  BEGIN
    EXECUTE IMMEDIATE p_sql;
    INSERT INTO poc.poc_result (scenario, test_name, outcome, stmt) VALUES (p_scn, p_test, 'OK', SUBSTR(p_sql,1,400));
  EXCEPTION WHEN OTHERS THEN
    l_err := SUBSTR(SQLERRM,1,200);
    INSERT INTO poc.poc_result (scenario, test_name, outcome, ora, stmt) VALUES (p_scn, p_test, 'FAIL', l_err, SUBSTR(p_sql,1,400));
  END;
  COMMIT;
END;
/
GRANT CREATE TABLE TO poc;
GRANT DROP TABLESPACE TO poc;

-- ---------------------------------------------------------------------------
-- Table shapes. Three old partitions in POC_H, one recent in POC_K.
-- ---------------------------------------------------------------------------
DECLARE
  c_parts CONSTANT VARCHAR2(600) :=
    ' PARTITION BY RANGE (d) ('
    || ' PARTITION p_o1 VALUES LESS THAN (DATE ''2020-01-01'') TABLESPACE poc_h,'
    || ' PARTITION p_o2 VALUES LESS THAN (DATE ''2021-01-01'') TABLESPACE poc_h,'
    || ' PARTITION p_o3 VALUES LESS THAN (DATE ''2022-01-01'') TABLESPACE poc_h,'
    || ' PARTITION p_n  VALUES LESS THAN (DATE ''2030-01-01'') TABLESPACE poc_k)';
  PROCEDURE fill(p_t VARCHAR2, p_cols VARCHAR2 DEFAULT 'd, n', p_vals VARCHAR2 DEFAULT 'n') IS
  BEGIN
    EXECUTE IMMEDIATE 'INSERT INTO poc.' || p_t || ' (' || p_cols || ') '
      || 'SELECT dt, ' || p_vals || ' FROM (SELECT DATE ''2019-06-01'' + LEVEL * 3 dt, LEVEL n FROM dual CONNECT BY LEVEL <= 800)';
    COMMIT;
  END;
BEGIN
  -- no index at all
  EXECUTE IMMEDIATE 'CREATE TABLE poc.s1_noidx (d DATE, n NUMBER)' || c_parts;
  fill('s1_noidx');
  -- local index
  EXECUTE IMMEDIATE 'CREATE TABLE poc.s2_local (d DATE, n NUMBER)' || c_parts;
  fill('s2_local');
  EXECUTE IMMEDIATE 'CREATE INDEX poc.s2_local_i ON poc.s2_local (n) LOCAL';
  -- local and global indexes
  EXECUTE IMMEDIATE 'CREATE TABLE poc.s3_global (d DATE, n NUMBER)' || c_parts;
  fill('s3_global');
  EXECUTE IMMEDIATE 'CREATE INDEX poc.s3_global_l ON poc.s3_global (d) LOCAL';
  EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX poc.s3_global_g ON poc.s3_global (n, d) TABLESPACE poc_k';
  -- SecureFile LOB, no user index
  EXECUTE IMMEDIATE 'CREATE TABLE poc.s4_lob (d DATE, n NUMBER, c CLOB) LOB (c) STORE AS SECUREFILE'  || c_parts;
  fill('s4_lob', 'd, n, c', 'n, RPAD(''x'', 3000, ''x'')');
  -- BasicFile LOB plus local index
  EXECUTE IMMEDIATE 'CREATE TABLE poc.s5_lobb (d DATE, n NUMBER, b CLOB) LOB (b) STORE AS BASICFILE' || c_parts;
  fill('s5_lobb', 'd, n, b', 'n, RPAD(''x'', 3000, ''x'')');
  EXECUTE IMMEDIATE 'CREATE INDEX poc.s5_lobb_i ON poc.s5_lobb (n) LOCAL';
  -- composite range-hash with local index
  EXECUTE IMMEDIATE 'CREATE TABLE poc.s6_comp (d DATE, n NUMBER) PARTITION BY RANGE (d) SUBPARTITION BY HASH (n) SUBPARTITIONS 2 ('
    || ' PARTITION p_o1 VALUES LESS THAN (DATE ''2020-01-01'') TABLESPACE poc_h,'
    || ' PARTITION p_o2 VALUES LESS THAN (DATE ''2021-01-01'') TABLESPACE poc_h,'
    || ' PARTITION p_o3 VALUES LESS THAN (DATE ''2022-01-01'') TABLESPACE poc_h,'
    || ' PARTITION p_n  VALUES LESS THAN (DATE ''2030-01-01'') TABLESPACE poc_k)';
  fill('s6_comp');
  EXECUTE IMMEDIATE 'CREATE INDEX poc.s6_comp_i ON poc.s6_comp (n) LOCAL';
  -- interval table whose range section sits in the offline tablespace
  EXECUTE IMMEDIATE 'CREATE TABLE poc.s7_intv (d DATE, n NUMBER) PARTITION BY RANGE (d) INTERVAL (NUMTOYMINTERVAL(1,''YEAR'')) STORE IN (poc_k) ('
    || ' PARTITION p_o1 VALUES LESS THAN (DATE ''2022-01-01'') TABLESPACE poc_h)';
  fill('s7_intv');
  EXECUTE IMMEDIATE 'CREATE INDEX poc.s7_intv_i ON poc.s7_intv (n) LOCAL';
  -- table for the plan's MOVE syntax tests, stays online
  EXECUTE IMMEDIATE 'CREATE TABLE poc.m1_move (d DATE, n NUMBER, c CLOB) LOB (c) STORE AS SECUREFILE' || c_parts;
  fill('m1_move', 'd, n, c', 'n, RPAD(''x'', 3000, ''x'')');
  EXECUTE IMMEDIATE 'CREATE INDEX poc.m1_move_l ON poc.m1_move (n) LOCAL';
  EXECUTE IMMEDIATE 'CREATE INDEX poc.m1_move_g ON poc.m1_move (n, d) TABLESPACE poc_k';
END;
/

-- ---------------------------------------------------------------------------
-- A. Plan statements, on online tablespaces
-- ---------------------------------------------------------------------------
BEGIN
  poc.t('MOVE','HOT partition + LOB + UPDATE INDEXES',
    'ALTER TABLE poc.m1_move MOVE PARTITION p_n TABLESPACE poc_k2 LOB (c) STORE AS (TABLESPACE poc_k2) UPDATE INDEXES PARALLEL 2 ONLINE');
  poc.t('MOVE','REBUILD local ONLINE into target',
    'ALTER INDEX poc.m1_move_l REBUILD PARTITION p_n TABLESPACE poc_k2 PARALLEL 2 ONLINE');
  poc.t('MOVE','COLD partition + LOB + UPDATE GLOBAL',
    'ALTER TABLE poc.m1_move MOVE PARTITION p_o1 TABLESPACE poc_k2 LOB (c) STORE AS (TABLESPACE poc_k2) UPDATE GLOBAL INDEXES PARALLEL 2');
  poc.t('MOVE','REBUILD local after COLD',
    'ALTER INDEX poc.m1_move_l REBUILD PARTITION p_o1 TABLESPACE poc_k2 PARALLEL 2');
  poc.t('MOVE','Default attributes table',
    'ALTER TABLE poc.m1_move MODIFY DEFAULT ATTRIBUTES TABLESPACE poc_k2');
  poc.t('MOVE','Default attributes LOB',
    'ALTER TABLE poc.m1_move MODIFY DEFAULT ATTRIBUTES LOB (c) (TABLESPACE poc_k2)');
  poc.t('MOVE','Default attributes index',
    'ALTER INDEX poc.m1_move_l MODIFY DEFAULT ATTRIBUTES TABLESPACE poc_k2');
  poc.t('MOVE','SET STORE IN on interval',
    'ALTER TABLE poc.s7_intv SET STORE IN (poc_k2)');
  poc.t('MOVE','FOR EXCHANGE accepts TABLESPACE',
    'CREATE TABLE poc.x_syntax TABLESPACE poc_k FOR EXCHANGE WITH TABLE poc.m1_move');
  -- Remove what M1_MOVE still has in POC_H while it is online, so that it does not affect test 5.
  poc.t('MOVE','Online DROP PARTITION (restored history)', 'ALTER TABLE poc.m1_move DROP PARTITION p_o2');
  poc.t('MOVE','Online DROP PARTITION (restored history)', 'ALTER TABLE poc.m1_move DROP PARTITION p_o3');
END;
/
PROMPT Dictionary verification of the moves (LOB, table and index partitions expected in POC_K2):
SELECT 'TABLE' k, partition_name, tablespace_name FROM dba_tab_partitions WHERE table_owner='POC' AND table_name='M1_MOVE' AND partition_name IN ('P_N','P_O1')
UNION ALL SELECT 'LOB', partition_name, tablespace_name FROM dba_lob_partitions WHERE table_owner='POC' AND table_name='M1_MOVE' AND partition_name IN ('P_N','P_O1')
UNION ALL SELECT 'INDEX', partition_name, tablespace_name||' '||status FROM dba_ind_partitions WHERE index_owner='POC' AND index_name='M1_MOVE_L' AND partition_name IN ('P_N','P_O1')
UNION ALL SELECT 'GLOBAL', index_name, tablespace_name||' '||status FROM dba_indexes WHERE owner='POC' AND index_name='M1_MOVE_G'
ORDER BY 1,2;
PROMPT Segment map check: LOB index partitions must match DBA_LOB_PARTITIONS.LOB_INDPART_NAME
SELECT s.segment_name, s.partition_name, s.segment_type, s.tablespace_name, lp.partition_name table_partition
FROM   dba_segments s
LEFT JOIN dba_lob_partitions lp ON lp.table_owner = s.owner AND lp.lob_indpart_name = s.partition_name
WHERE  s.owner = 'POC' AND s.segment_name LIKE 'SYS_IL%' AND rownum <= 20;

-- ---------------------------------------------------------------------------
-- B. Take the tablespace offline, as after a partial restore
-- ---------------------------------------------------------------------------
ALTER TABLESPACE poc_h OFFLINE;

BEGIN
  FOR r IN (SELECT column_value t FROM TABLE(sys.odcivarchar2list('S1_NOIDX','S2_LOCAL','S3_GLOBAL','S4_LOB','S5_LOBB','S6_COMP'))) LOOP
    -- 1. direct drop
    poc.t(r.t, '1 DROP PARTITION offline', 'ALTER TABLE poc.' || r.t || ' DROP PARTITION p_o1');
    -- 2. exchange route, as PCOPY_TARGET does it
    poc.t(r.t, '2a CREATE FOR EXCHANGE', 'CREATE TABLE poc.cx_' || r.t || ' TABLESPACE poc_k FOR EXCHANGE WITH TABLE poc.' || r.t);
    IF r.t = 'S6_COMP' THEN
      -- composite: the route of the package, subpartition by subpartition
      FOR s IN (SELECT subpartition_name n, subpartition_position p FROM dba_tab_subpartitions
                WHERE table_owner='POC' AND table_name='S6_COMP' AND partition_name='P_O2' ORDER BY 2) LOOP
        IF s.p > 1 THEN
          poc.t(r.t, '2a CREATE FOR EXCHANGE (sub)', 'CREATE TABLE poc.cx_s6_' || s.p || ' TABLESPACE poc_k FOR EXCHANGE WITH TABLE poc.s6_comp');
          poc.t(r.t, '2b EXCHANGE SUBPARTITION', 'ALTER TABLE poc.s6_comp EXCHANGE SUBPARTITION ' || s.n || ' WITH TABLE poc.cx_s6_' || s.p || ' EXCLUDING INDEXES WITHOUT VALIDATION');
        ELSE
          poc.t(r.t, '2b EXCHANGE SUBPARTITION', 'ALTER TABLE poc.s6_comp EXCHANGE SUBPARTITION ' || s.n || ' WITH TABLE poc.cx_s6_comp EXCLUDING INDEXES WITHOUT VALIDATION');
        END IF;
      END LOOP;
    ELSE
      poc.t(r.t, '2b EXCHANGE', 'ALTER TABLE poc.' || r.t || ' EXCHANGE PARTITION p_o2 WITH TABLE poc.cx_' || r.t || ' EXCLUDING INDEXES WITHOUT VALIDATION');
    END IF;
    poc.t(r.t, '2c DROP PARTITION after exchange', 'ALTER TABLE poc.' || r.t || ' DROP PARTITION p_o2');
    -- 3. recent data readable meanwhile (pruned)
    poc.t(r.t, '3 read recent partition', 'DECLARE n NUMBER; BEGIN SELECT COUNT(*) INTO n FROM poc.' || r.t || ' PARTITION (p_n); END;');
  END LOOP;

  -- interval: last range partition, after SET INTERVAL ()
  poc.t('S7_INTV', '1 DROP range partition directly', 'ALTER TABLE poc.s7_intv DROP PARTITION p_o1');
  poc.t('S7_INTV', '2a SET INTERVAL ()', 'ALTER TABLE poc.s7_intv SET INTERVAL ()');
  poc.t('S7_INTV', '2b CREATE FOR EXCHANGE', 'CREATE TABLE poc.cx_s7 TABLESPACE poc_k FOR EXCHANGE WITH TABLE poc.s7_intv');
  poc.t('S7_INTV', '2c EXCHANGE', 'ALTER TABLE poc.s7_intv EXCHANGE PARTITION p_o1 WITH TABLE poc.cx_s7 EXCLUDING INDEXES WITHOUT VALIDATION');
  poc.t('S7_INTV', '2d DROP PARTITION', 'ALTER TABLE poc.s7_intv DROP PARTITION p_o1');
  poc.t('S7_INTV', '2e SET INTERVAL back', 'ALTER TABLE poc.s7_intv SET INTERVAL (NUMTOYMINTERVAL(1,''YEAR''))');

  -- p_o3 is left in place on purpose for the fallback test: drop every table index, then drop the partition.
  FOR r IN (SELECT column_value t FROM TABLE(sys.odcivarchar2list('S2_LOCAL','S3_GLOBAL','S4_LOB','S5_LOBB','S6_COMP'))) LOOP
    FOR i IN (SELECT owner, index_name FROM dba_indexes WHERE table_owner='POC' AND table_name=r.t AND index_type <> 'LOB') LOOP
      poc.t(r.t, '4a DROP INDEX for fallback', 'DROP INDEX ' || i.owner || '.' || i.index_name);
    END LOOP;
    poc.t(r.t, '4b DROP PARTITION with no index', 'ALTER TABLE poc.' || r.t || ' DROP PARTITION p_o3');
  END LOOP;
  poc.t('S1_NOIDX', '4b DROP PARTITION with no index', 'ALTER TABLE poc.s1_noidx DROP PARTITION p_o3');
  poc.t('ALL', '5 DROP TABLESPACE offline', 'DROP TABLESPACE poc_h INCLUDING CONTENTS AND DATAFILES CASCADE CONSTRAINTS');
END;
/

COLUMN scenario FORMAT A10
COLUMN test_name FORMAT A36
COLUMN outcome FORMAT A5
COLUMN ora FORMAT A90
SPOOL poc_result.log
SELECT scenario, test_name, outcome, ora FROM poc.poc_result ORDER BY seq;
PROMPT
PROMPT Leftover objects in POC_H (none expected when test 5 is OK):
SELECT segment_name, partition_name, segment_type FROM dba_segments WHERE tablespace_name = 'POC_H';
SPOOL OFF

PROMPT Interpretation:
PROMPT  S4_LOB/S5_LOBB test 2c OK      -> LOB_HIST_SKIP can be Y and p_method stays EXCHANGE
PROMPT  S4_LOB/S5_LOBB test 2b/2c FAIL -> keep LOB_HIST_SKIP=N. LOB history is restored, then dropped
PROMPT  S2/S3 test 2c FAIL, 4b OK      -> exchange is not enough: the fallback is drop indexes, drop partition, recreate indexes
PROMPT  Test 5 FAIL with ORA-14404     -> a partition of some table is still inside POC_H
PROMPT This covers OFFLINE tablespaces. The final rehearsal must be a real partial restore of a small database (see README).

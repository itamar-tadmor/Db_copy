-- =============================================================================
-- 02_tables.sql  -  run as PCOPY.  Config, log and mapping tables.
-- =============================================================================
SET DEFINE OFF

CREATE TABLE pcopy_config (
  param_name  VARCHAR2(40) PRIMARY KEY,
  param_value VARCHAR2(400),
  description VARCHAR2(400)
);

-- Per-table overrides, for keys that are not DATE/TIMESTAMP or tables that must be forced.
CREATE TABLE pcopy_table_rule (
  owner       VARCHAR2(128) NOT NULL,
  table_name  VARCHAR2(128) NOT NULL,
  key_format  VARCHAR2(30),            -- date format of a NUMBER/VARCHAR2 key: YYYYMMDD, YYYYMM, YYYY...
  force_class VARCHAR2(10) CHECK (force_class IN ('KEEP','HIST')), -- KEEP = take the whole table
  note        VARCHAR2(400),
  CONSTRAINT pcopy_table_rule_pk PRIMARY KEY (owner, table_name)
);

-- One row per logical process execution (mapping + check + plan + execution share a RUN_ID)
CREATE TABLE pcopy_run (
  run_id       NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_type     VARCHAR2(30) NOT NULL,
  cutoff_date  DATE,
  db_name      VARCHAR2(30),
  dbid         NUMBER,
  map_scn      NUMBER,                  -- SCN at end of mapping. The restore must recover past it.
  started_at   TIMESTAMP DEFAULT SYSTIMESTAMP,
  ended_at     TIMESTAMP,
  status       VARCHAR2(20) DEFAULT 'RUNNING',
  os_user      VARCHAR2(128) DEFAULT SYS_CONTEXT('USERENV','OS_USER'),
  note         VARCHAR2(400)
);

-- Every action of every package lands here (autonomous transaction).
CREATE TABLE pcopy_log (
  log_id          NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id          NUMBER,
  log_time        TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
  log_level       VARCHAR2(8) NOT NULL,   -- INFO / WARN / ERROR
  module_name     VARCHAR2(30),
  action          VARCHAR2(60),
  step_id         NUMBER,
  owner           VARCHAR2(128),
  object_name     VARCHAR2(128),
  partition_name  VARCHAR2(128),
  tablespace_name VARCHAR2(128),
  ora_code        NUMBER,
  message         VARCHAR2(4000),
  error_stack     VARCHAR2(4000),
  sql_text        CLOB,
  alert_written   CHAR(1) DEFAULT 'N',
  session_info    VARCHAR2(200) DEFAULT SYS_CONTEXT('USERENV','INSTANCE')||':'||SYS_CONTEXT('USERENV','SID')
);
CREATE INDEX pcopy_log_i1 ON pcopy_log (run_id, log_level, log_time);

CREATE TABLE pcopy_seg_snap (
  run_id NUMBER NOT NULL, owner VARCHAR2(128), segment_name VARCHAR2(128), partition_name VARCHAR2(128),
  segment_type VARCHAR2(30), tablespace_name VARCHAR2(30), bytes NUMBER
);
CREATE INDEX pcopy_seg_snap_i1 ON pcopy_seg_snap (run_id, owner, segment_name, partition_name);

CREATE TABLE pcopy_partition_map (
  run_id             NUMBER NOT NULL,
  table_owner        VARCHAR2(128) NOT NULL,
  table_name         VARCHAR2(128) NOT NULL,
  partition_name     VARCHAR2(128) NOT NULL,
  partition_position NUMBER,
  is_composite       VARCHAR2(3),
  partitioning_type  VARCHAR2(30),
  interval_expr      VARCHAR2(1000),
  key_type           VARCHAR2(106),
  high_value         VARCHAR2(4000),
  high_value_dt      DATE,
  data_class         VARCHAR2(4) NOT NULL,   -- HIST / KEEP
  class_reason       VARCHAR2(60),
  complex_reason     VARCHAR2(60),           -- not null = cannot rely on offline cleanup on target
  CONSTRAINT pcopy_partition_map_pk PRIMARY KEY (run_id, table_owner, table_name, partition_name)
);
CREATE INDEX pcopy_partition_map_i1 ON pcopy_partition_map (run_id, table_owner, table_name, partition_position);

-- One row for each logical storage unit, with or without an allocated segment.
CREATE TABLE pcopy_segment_map (
  run_id             NUMBER NOT NULL,
  seg_owner          VARCHAR2(128),
  seg_name           VARCHAR2(128),
  seg_partition      VARCHAR2(128),
  segment_type       VARCHAR2(30),
  tablespace_name    VARCHAR2(30),
  gb                 NUMBER DEFAULT 0,
  role               VARCHAR2(20) NOT NULL,
     -- TABLE, TABLE_PART, TABLE_SUB, INDEX, INDEX_PART, INDEX_SUB,
     -- LOB, LOB_PART, LOB_SUB, LOBINDEX, OTHER
  table_owner        VARCHAR2(128),
  table_name         VARCHAR2(128),
  table_partition    VARCHAR2(128),
  table_subpartition VARCHAR2(128),
  lob_column         VARCHAR2(4000),
  is_global          CHAR(1) DEFAULT 'N',
  data_class         VARCHAR2(4) NOT NULL,
  target_ts          VARCHAR2(30)            -- filled by PCOPY_PLAN. Null = stays where it is.
);
CREATE INDEX pcopy_segment_map_i1 ON pcopy_segment_map (run_id, seg_owner, seg_name, seg_partition);
CREATE INDEX pcopy_segment_map_i2 ON pcopy_segment_map (run_id, tablespace_name, data_class);
CREATE INDEX pcopy_segment_map_i3 ON pcopy_segment_map (run_id, table_owner, table_name, table_partition);

CREATE TABLE pcopy_ts_map (
  run_id                NUMBER NOT NULL,
  tablespace_name       VARCHAR2(30) NOT NULL,
  contents              VARCHAR2(21),
  status                VARCHAR2(9),
  block_size            NUMBER,
  ssm                   VARCHAR2(6),
  encrypted             VARCHAR2(3),
  bigfile               VARCHAR2(3),
  alloc_gb              NUMBER,
  max_gb                NUMBER,
  used_gb               NUMBER,
  hist_gb               NUMBER DEFAULT 0,
  keep_gb               NUMBER DEFAULT 0,
  hist_lob_gb           NUMBER DEFAULT 0,
  keep_lob_gb           NUMBER DEFAULT 0,
  hist_units            NUMBER DEFAULT 0,
  keep_units            NUMBER DEFAULT 0,
  unmovable_units       NUMBER DEFAULT 0,
  complex_hist_units    NUMBER DEFAULT 0,
  complex_hist_gb       NUMBER DEFAULT 0,
  classification        VARCHAR2(12),   -- SYSTEM, PURE_HIST, PURE_KEEP, MIXED, EMPTY
  decision              VARCHAR2(14),   -- SKIP (not restored) / RESTORE / RESTORE_DROP (restored, emptied on target)
  action                VARCHAR2(15),   -- NONE / LEAVE / MOVE_KEEP_OUT / MOVE_HIST_OUT
  decision_reason       VARCHAR2(400),
  is_override           CHAR(1) DEFAULT 'N',
  CONSTRAINT pcopy_ts_map_pk PRIMARY KEY (run_id, tablespace_name)
);

CREATE TABLE pcopy_violation (
  violation_id    NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id          NUMBER NOT NULL,
  rule_id         VARCHAR2(6) NOT NULL,
  severity        VARCHAR2(8) NOT NULL,   -- CRITICAL blocks the skip / HIGH must fix / WARN / INFO
  fix_type        VARCHAR2(10),           -- PLAN = plan fixes it / MANUAL / TARGET = handled on target / NONE
  owner           VARCHAR2(128),
  object_name     VARCHAR2(128),
  partition_name  VARCHAR2(128),
  tablespace_name VARCHAR2(30),
  gb              NUMBER,
  detail          VARCHAR2(1000)
);
CREATE INDEX pcopy_violation_i1 ON pcopy_violation (run_id, severity, rule_id);

CREATE TABLE pcopy_plan_step (
  step_id        NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  run_id         NUMBER NOT NULL,
  seq            NUMBER NOT NULL,
  phase          NUMBER NOT NULL,
     -- 10 CREATE_TS, 20 QUOTA, 30 TS_RW, 40 MOVE+REBUILD_LOCAL, 50 REBUILD_GLOBAL,
     -- 60 DEFAULT_ATTR, 70 RESTORE_DEGREE, 80 TS_RO
  step_type      VARCHAR2(20) NOT NULL,
  owner          VARCHAR2(128),
  object_name    VARCHAR2(128),
  partition_name VARCHAR2(128),
  source_ts      VARCHAR2(30),
  target_ts      VARCHAR2(30),
  est_gb         NUMBER DEFAULT 0,
  lob_gb         NUMBER DEFAULT 0,
  data_class     VARCHAR2(4),
  move_mode      VARCHAR2(4),              -- HOT / COLD
  dep_step_id    NUMBER,
  expected_value VARCHAR2(40),             -- RESTORE_DEGREE: degree to return to
  sql_text       CLOB NOT NULL,
  status         VARCHAR2(10) DEFAULT 'PENDING' NOT NULL, -- PENDING/RUNNING/DONE/FAILED/SKIPPED/MANUAL
  attempts       NUMBER DEFAULT 0,
  started_at     TIMESTAMP,
  ended_at       TIMESTAMP,
  elapsed_sec    NUMBER,
  redo_mb        NUMBER,
  ora_code       NUMBER,
  error_message  VARCHAR2(4000),
  note           VARCHAR2(400)
);
CREATE INDEX pcopy_plan_step_i1 ON pcopy_plan_step (run_id, status, seq);
CREATE INDEX pcopy_plan_step_i2 ON pcopy_plan_step (run_id, owner, object_name);

CREATE TABLE pcopy_precheck (
  run_id     NUMBER NOT NULL,
  batch_id   NUMBER NOT NULL,
  stage      VARCHAR2(5) NOT NULL,   -- PRE / POST
  check_id   VARCHAR2(6) NOT NULL,
  check_name VARCHAR2(100),
  status     VARCHAR2(6) NOT NULL,   -- PASS / WARN / FAIL
  detail     VARCHAR2(2000),
  checked_at TIMESTAMP DEFAULT SYSTIMESTAMP
);
CREATE INDEX pcopy_precheck_i1 ON pcopy_precheck (run_id, batch_id);

-- State before the moves, so post-checks only blame what the process changed.
CREATE TABLE pcopy_baseline (
  run_id NUMBER NOT NULL, kind VARCHAR2(20) NOT NULL,
  owner VARCHAR2(128), object_name VARCHAR2(128), partition_name VARCHAR2(128), status VARCHAR2(20)
);
CREATE INDEX pcopy_baseline_i1 ON pcopy_baseline (run_id, kind, owner, object_name, partition_name);

INSERT INTO pcopy_config VALUES ('CUTOFF_MONTHS','24','Months to keep. A partition is HIST when HIGH_VALUE <= cutoff');
INSERT INTO pcopy_config VALUES ('CUTOFF_FIXED_DATE',NULL,'YYYY-MM-DD. When set, overrides CUTOFF_MONTHS');
INSERT INTO pcopy_config VALUES ('MIN_SAVING_GB','100','A mixed tablespace is reorganized only if it saves at least this many GB');
INSERT INTO pcopy_config VALUES ('LOB_HIST_SKIP','N','Y only after the POC proved offline cleanup works for LOB tables on your version');
INSERT INTO pcopy_config VALUES ('FIX_HIST_SPLIT','Y','Y = also bring all segments of a HIST partition into the same skipped tablespace');
INSERT INTO pcopy_config VALUES ('PREFER_EXISTING_HIST_TS','Y','Y = reopen existing read-only history tablespaces. N = always create new ones');
INSERT INTO pcopy_config VALUES ('HIST_TS_PREFIX','HIST_','Prefix for new history tablespaces');
INSERT INTO pcopy_config VALUES ('KEEP_TS_SUFFIX','_KP','Suffix for new tablespaces receiving recent data');
INSERT INTO pcopy_config VALUES ('SPACE_FACTOR','1.2','Required free space = estimated size * factor');
INSERT INTO pcopy_config VALUES ('MOVE_MODE_HIST','COLD','COLD = no ONLINE, local index partition goes UNUSABLE until rebuilt. HOT = ONLINE');
INSERT INTO pcopy_config VALUES ('MOVE_MODE_KEEP','HOT','Recent data: use HOT');
INSERT INTO pcopy_config VALUES ('PARALLEL_DEGREE','8','Degree for MOVE and REBUILD');
INSERT INTO pcopy_config VALUES ('DDL_LOCK_TIMEOUT','60','Seconds');
INSERT INTO pcopy_config VALUES ('LOCK_RETRIES','3','Retries on ORA-00054');
INSERT INTO pcopy_config VALUES ('RESUMABLE_TIMEOUT','3600','Seconds a statement waits on out-of-space before failing');
INSERT INTO pcopy_config VALUES ('STOP_ON_ERROR','Y','Y = stop the run at the first failed step');
INSERT INTO pcopy_config VALUES ('STOP_FLAG','N','Set to Y from another session: the run stops before its next step');
INSERT INTO pcopy_config VALUES ('WINDOW_START_HH24',NULL,'Hour moves may start, e.g. 20. Null = no window');
INSERT INTO pcopy_config VALUES ('WINDOW_END_HH24',NULL,'Hour moves must not start after, e.g. 6');
INSERT INTO pcopy_config VALUES ('MAX_FRA_USED_PCT','75','Stop when FRA usage is above this');
INSERT INTO pcopy_config VALUES ('MAX_APPLY_LAG_SEC','1800','Stop when Data Guard apply/transport lag exceeds this');
INSERT INTO pcopy_config VALUES ('MAX_BACKUP_AGE_DAYS','7','FAIL when the last successful full/level 0 backup is older');
INSERT INTO pcopy_config VALUES ('PRECHECK_MAX_AGE_HOURS','24','Execution refuses to start on an older precheck');
INSERT INTO pcopy_config VALUES ('HOT_HIST_DML_ROWS','1000','WARN when a HIST partition shows more modified rows than this');
INSERT INTO pcopy_config VALUES ('BASICFILE_WARN_GB','500','WARN for BasicFile LOBs above this size');
INSERT INTO pcopy_config VALUES ('MB_PER_SEC_TABLE','300','Throughput estimate for reports, tables and indexes');
INSERT INTO pcopy_config VALUES ('MB_PER_SEC_LOB','80','Throughput estimate for reports, LOBs');
INSERT INTO pcopy_config VALUES ('PROD_DB_UNIQUE_NAME',NULL,'Filled at install. Target cleanup refuses to run under this DB_UNIQUE_NAME');
UPDATE pcopy_config SET param_value = (SELECT db_unique_name FROM v$database) WHERE param_name = 'PROD_DB_UNIQUE_NAME';
COMMIT;

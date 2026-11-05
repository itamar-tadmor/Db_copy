-- =============================================================================
-- 11_reports.sql <run_id>  -  read-only reports over the PCOPY tables, as PCOPY.
-- =============================================================================
SET LINESIZE 240 PAGESIZE 500 TRIMSPOOL ON VERIFY OFF TAB OFF
DEFINE run = &1
SPOOL report_run_&&run..log
COLUMN tablespace_name FORMAT A28
COLUMN decision_reason FORMAT A80
COLUMN detail FORMAT A90
COLUMN owner FORMAT A16
COLUMN object_name FORMAT A30
COLUMN partition_name FORMAT A22
COLUMN message FORMAT A100
COLUMN check_name FORMAT A44

PROMPT ===== R1 Summary: what the copy will cost =====
SELECT decision, COUNT(*) ts_count, ROUND(SUM(alloc_gb)/1024,1) alloc_tb,
       ROUND(SUM(hist_gb)/1024,1) hist_tb, ROUND(SUM(keep_gb)/1024,1) keep_tb
FROM   pcopy_ts_map WHERE run_id = &&run GROUP BY decision ORDER BY 1;

PROMPT ===== R2 Tablespace decisions =====
SELECT tablespace_name, status, classification, decision, action,
       ROUND(alloc_gb) alloc_gb, ROUND(hist_gb) hist_gb, ROUND(keep_gb) keep_gb, ROUND(hist_lob_gb) hist_lob, ROUND(complex_hist_gb) complex_gb,
       unmovable_units unmov, is_override ovr, decision_reason
FROM   pcopy_ts_map WHERE run_id = &&run AND classification <> 'SYSTEM'
ORDER  BY CASE classification WHEN 'MIXED' THEN 1 WHEN 'PURE_HIST' THEN 2 ELSE 3 END, hist_gb DESC;

PROMPT ===== R3 Violations by rule =====
SELECT rule_id, severity, fix_type, COUNT(*) cnt, ROUND(SUM(gb)) gb, MIN(detail) example
FROM   pcopy_violation WHERE run_id = &&run
GROUP  BY rule_id, severity, fix_type
ORDER  BY CASE severity WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'WARN' THEN 3 ELSE 4 END, rule_id;

PROMPT ===== R4 Violations that block the process (first 200) =====
SELECT rule_id, severity, fix_type, owner, object_name, partition_name, tablespace_name, ROUND(gb,1) gb, detail
FROM   pcopy_violation WHERE run_id = &&run AND severity IN ('CRITICAL','HIGH')
ORDER  BY severity, rule_id, gb DESC NULLS LAST FETCH FIRST 200 ROWS ONLY;

PROMPT ===== R5 Plan size and duration estimate =====
SELECT phase, step_type, status, COUNT(*) steps, ROUND(SUM(est_gb)) gb, ROUND(SUM(lob_gb)) lob_gb,
       ROUND(((SUM(est_gb) - SUM(lob_gb)) * 1024 / (SELECT TO_NUMBER(param_value) FROM pcopy_config WHERE param_name = 'MB_PER_SEC_TABLE')
            + SUM(lob_gb) * 1024 / (SELECT TO_NUMBER(param_value) FROM pcopy_config WHERE param_name = 'MB_PER_SEC_LOB')) / 3600, 1) est_hours,
       ROUND(SUM(redo_mb)/1024) actual_redo_gb, ROUND(SUM(elapsed_sec)/3600,1) actual_hours
FROM   pcopy_plan_step WHERE run_id = &&run
GROUP  BY phase, step_type, status ORDER BY 1,2,3;

PROMPT ===== R6 LOB inventory for this run =====
SELECT s.table_owner owner, s.table_name object_name, s.lob_column, s.data_class, l.securefile,
       ROUND(SUM(s.gb)) gb, COUNT(*) units, MIN(s.tablespace_name) first_ts, COUNT(DISTINCT s.tablespace_name) ts_cnt,
       COUNT(s.target_ts) to_move
FROM   pcopy_segment_map s
LEFT JOIN dba_lobs l ON l.owner = s.table_owner AND l.table_name = s.table_name AND l.column_name = s.lob_column
WHERE  s.run_id = &&run AND s.role IN ('LOB','LOB_PART','LOB_SUB')
GROUP  BY s.table_owner, s.table_name, s.lob_column, s.data_class, l.securefile
ORDER  BY gb DESC FETCH FIRST 100 ROWS ONLY;

PROMPT ===== R7 Last precheck =====
SELECT check_id, check_name, status, SUBSTR(detail,1,120) detail FROM pcopy_precheck
WHERE  run_id = &&run AND batch_id = (SELECT MAX(batch_id) FROM pcopy_precheck WHERE run_id = &&run)
ORDER  BY CASE status WHEN 'FAIL' THEN 1 WHEN 'WARN' THEN 2 ELSE 3 END, check_id;

PROMPT ===== R8 Errors of this run =====
SELECT log_time, module_name, action, step_id, owner, object_name, partition_name, ora_code, message
FROM   pcopy_log WHERE run_id = &&run AND log_level = 'ERROR' ORDER BY log_id DESC FETCH FIRST 50 ROWS ONLY;

SPOOL OFF

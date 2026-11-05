-- =============================================================================
-- 03_pkg_util.sql  -  config, logging (autonomous) and writing errors to the alert log.
-- Alert log format, so monitoring can match on it:
--   PCOPY-ERROR run=<id> step=<id> module=<m> action=<a> obj=<o.t:p> ORA-<n> <message>
-- =============================================================================
SET DEFINE OFF

CREATE OR REPLACE PACKAGE pcopy_util AS
  FUNCTION  cfg(p_name VARCHAR2) RETURN VARCHAR2;
  FUNCTION  cfg_num(p_name VARCHAR2) RETURN NUMBER;
  FUNCTION  q(p_name VARCHAR2) RETURN VARCHAR2;           -- quoted identifier
  FUNCTION  new_run(p_type VARCHAR2, p_cutoff DATE DEFAULT NULL, p_note VARCHAR2 DEFAULT NULL) RETURN NUMBER;
  PROCEDURE end_run(p_run NUMBER, p_status VARCHAR2);
  PROCEDURE alert(p_msg VARCHAR2);
  PROCEDURE write_log(p_run NUMBER, p_level VARCHAR2, p_module VARCHAR2, p_action VARCHAR2, p_message VARCHAR2,
                      p_step NUMBER DEFAULT NULL, p_owner VARCHAR2 DEFAULT NULL, p_object VARCHAR2 DEFAULT NULL,
                      p_partition VARCHAR2 DEFAULT NULL, p_ts VARCHAR2 DEFAULT NULL, p_sql CLOB DEFAULT NULL);
  -- Call from an exception handler: logs SQLCODE and stack, and writes to the alert log.
  PROCEDURE log_error(p_run NUMBER, p_module VARCHAR2, p_action VARCHAR2, p_message VARCHAR2 DEFAULT NULL,
                      p_step NUMBER DEFAULT NULL, p_owner VARCHAR2 DEFAULT NULL, p_object VARCHAR2 DEFAULT NULL,
                      p_partition VARCHAR2 DEFAULT NULL, p_ts VARCHAR2 DEFAULT NULL, p_sql CLOB DEFAULT NULL,
                      p_code NUMBER DEFAULT NULL, p_errm VARCHAR2 DEFAULT NULL);
END pcopy_util;
/

CREATE OR REPLACE PACKAGE BODY pcopy_util AS

  FUNCTION cfg(p_name VARCHAR2) RETURN VARCHAR2 IS
    l_v pcopy_config.param_value%TYPE;
  BEGIN
    SELECT param_value INTO l_v FROM pcopy_config WHERE param_name = p_name;
    RETURN l_v;
  EXCEPTION WHEN NO_DATA_FOUND THEN
    RAISE_APPLICATION_ERROR(-20100, 'PCOPY_CONFIG parameter missing: ' || p_name);
  END cfg;

  FUNCTION cfg_num(p_name VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN TO_NUMBER(cfg(p_name));
  END cfg_num;

  FUNCTION q(p_name VARCHAR2) RETURN VARCHAR2 IS
  BEGIN
    RETURN '"' || REPLACE(p_name, '"', '""') || '"';
  END q;

  FUNCTION new_run(p_type VARCHAR2, p_cutoff DATE DEFAULT NULL, p_note VARCHAR2 DEFAULT NULL) RETURN NUMBER IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_run NUMBER; l_db VARCHAR2(30); l_dbid NUMBER;
  BEGIN
    SELECT name, dbid INTO l_db, l_dbid FROM v$database;
    INSERT INTO pcopy_run (run_type, cutoff_date, db_name, dbid, note)
    VALUES (p_type, p_cutoff, l_db, l_dbid, p_note)
    RETURNING run_id INTO l_run;
    COMMIT;
    RETURN l_run;
  END new_run;

  PROCEDURE end_run(p_run NUMBER, p_status VARCHAR2) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    UPDATE pcopy_run SET ended_at = SYSTIMESTAMP, status = p_status WHERE run_id = p_run;
    COMMIT;
  END end_run;

  PROCEDURE alert(p_msg VARCHAR2) IS
  BEGIN
    -- dest 2 = alert log. Single line, so grep based monitoring sees the whole message.
    sys.dbms_system.ksdwrt(2, SUBSTR(REPLACE(REPLACE(p_msg, CHR(10), ' | '), CHR(13), ''), 1, 2000));
  EXCEPTION WHEN OTHERS THEN NULL;  -- alert writing must never hide the original error
  END alert;

  PROCEDURE write_log(p_run NUMBER, p_level VARCHAR2, p_module VARCHAR2, p_action VARCHAR2, p_message VARCHAR2,
                      p_step NUMBER DEFAULT NULL, p_owner VARCHAR2 DEFAULT NULL, p_object VARCHAR2 DEFAULT NULL,
                      p_partition VARCHAR2 DEFAULT NULL, p_ts VARCHAR2 DEFAULT NULL, p_sql CLOB DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
  BEGIN
    INSERT INTO pcopy_log (run_id, log_level, module_name, action, step_id, owner, object_name,
                           partition_name, tablespace_name, message, sql_text)
    VALUES (p_run, p_level, p_module, p_action, p_step, p_owner, p_object, p_partition, p_ts,
            SUBSTR(p_message, 1, 4000), p_sql);
    COMMIT;
  END write_log;

  PROCEDURE log_error(p_run NUMBER, p_module VARCHAR2, p_action VARCHAR2, p_message VARCHAR2 DEFAULT NULL,
                      p_step NUMBER DEFAULT NULL, p_owner VARCHAR2 DEFAULT NULL, p_object VARCHAR2 DEFAULT NULL,
                      p_partition VARCHAR2 DEFAULT NULL, p_ts VARCHAR2 DEFAULT NULL, p_sql CLOB DEFAULT NULL,
                      p_code NUMBER DEFAULT NULL, p_errm VARCHAR2 DEFAULT NULL) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
    l_code  NUMBER := NVL(p_code, SQLCODE);
    l_errm  VARCHAR2(4000) := NVL(p_errm, SQLERRM);
    l_stack VARCHAR2(4000) := SUBSTR(DBMS_UTILITY.format_error_stack || DBMS_UTILITY.format_error_backtrace, 1, 4000);
    l_msg   VARCHAR2(4000);
  BEGIN
    INSERT INTO pcopy_log (run_id, log_level, module_name, action, step_id, owner, object_name, partition_name,
                           tablespace_name, ora_code, message, error_stack, sql_text, alert_written)
    VALUES (p_run, 'ERROR', p_module, p_action, p_step, p_owner, p_object, p_partition, p_ts, l_code,
            SUBSTR(NVL(p_message || ': ', '') || l_errm, 1, 4000), l_stack, p_sql, 'Y');
    COMMIT;
    l_msg := 'PCOPY-ERROR run=' || p_run || ' step=' || NVL(TO_CHAR(p_step), '-') || ' module=' || p_module
          || ' action=' || p_action
          || ' obj=' || p_owner || '.' || p_object || CASE WHEN p_partition IS NOT NULL THEN ':' || p_partition END
          || ' ' || l_errm || CASE WHEN p_message IS NOT NULL THEN ' (' || p_message || ')' END;
    alert(l_msg);
  END log_error;

END pcopy_util;
/
SHOW ERRORS

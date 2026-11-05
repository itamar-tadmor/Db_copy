-- Run on production as PCOPY, after 01_user_grants.sql was run as SYS.
-- The scripts create the PCOPY tables and packages and do not touch application objects.
WHENEVER SQLERROR EXIT FAILURE
@@02_tables.sql
WHENEVER SQLERROR CONTINUE
@@03_pkg_util.sql
@@04_pkg_map.sql
@@05_pkg_check.sql
@@06_pkg_plan.sql
@@07_pkg_precheck.sql
@@08_pkg_exec.sql
@@09_pkg_target.sql

PROMPT ===== Objects that did not compile (expect none) =====
SELECT object_type, object_name, status FROM user_objects WHERE status <> 'VALID';
SELECT name, type, line, position, text FROM user_errors ORDER BY name, type, sequence;

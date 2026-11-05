-- =============================================================================
-- 01_user_grants.sql  -  run as SYS on PRODUCTION (in the PDB when using multitenant)
-- Creates the dedicated PCOPY schema and tablespace.
-- PCOPY_TS must always be restored: never put it in a skip list.
-- Keep the account locked outside of work windows and revoke the *ANY* privileges when done.
-- =============================================================================
SET DEFINE ON VERIFY OFF
ACCEPT pcopy_pwd CHAR PROMPT 'Password for PCOPY: ' HIDE

CREATE TABLESPACE pcopy_ts DATAFILE SIZE 5G AUTOEXTEND ON NEXT 1G MAXSIZE 200G
  EXTENT MANAGEMENT LOCAL AUTOALLOCATE SEGMENT SPACE MANAGEMENT AUTO;

CREATE USER pcopy IDENTIFIED BY "&pcopy_pwd"
  DEFAULT TABLESPACE pcopy_ts TEMPORARY TABLESPACE temp QUOTA UNLIMITED ON pcopy_ts;

GRANT CREATE SESSION, CREATE TABLE, CREATE PROCEDURE, CREATE TYPE, CREATE SEQUENCE TO pcopy;

-- Dictionary access (direct grants: roles do not work inside definer's rights PL/SQL)
GRANT SELECT ANY DICTIONARY TO pcopy;
GRANT EXECUTE ON sys.dbms_tts TO pcopy;

-- Writing to the alert log
GRANT EXECUTE ON sys.dbms_system TO pcopy;

-- Move / rebuild / tablespace management
GRANT ALTER ANY TABLE, ALTER ANY INDEX, ANALYZE ANY TO pcopy;
GRANT ALTER TABLESPACE, CREATE TABLESPACE, MANAGE TABLESPACE TO pcopy;
GRANT ALTER USER TO pcopy;      -- phase 20 only: ALTER USER ... QUOTA. Remove it if the DBA runs quotas by hand.
GRANT RESUMABLE TO pcopy;
GRANT UNLIMITED TABLESPACE TO pcopy;

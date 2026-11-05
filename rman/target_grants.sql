-- Run as SYS on the TARGET ONLY, after the restore opened. Never on production.
-- PCOPY_TARGET needs these for exchange tables and for dropping tablespaces.
DECLARE
  l_u VARCHAR2(30); l_p VARCHAR2(30);
BEGIN
  SELECT db_unique_name INTO l_u FROM v$database;
  SELECT param_value INTO l_p FROM pcopy.pcopy_config WHERE param_name = 'PROD_DB_UNIQUE_NAME';
  IF l_u = l_p THEN
    RAISE_APPLICATION_ERROR(-20199, 'This is production. Stopping.');
  END IF;
END;
/
GRANT CREATE ANY TABLE, DROP ANY TABLE, DROP TABLESPACE TO pcopy;
ALTER USER pcopy ACCOUNT UNLOCK;

-- Optional teardown: removes EVERY object this demo created. Irreversible.
-- Run as a user with ACCOUNTADMIN, in the demo account only, after you no
-- longer need the data, model, predictions or experiment history.
USE ROLE ACCOUNTADMIN;

-- Stop here unless this is the demo account.
EXECUTE IMMEDIATE $$
DECLARE
  wrong_account EXCEPTION (-20099, 'Refusing cleanup: not the <YOUR_ACCOUNT> demo account');
BEGIN
  IF (CURRENT_ACCOUNT_NAME() <> '<YOUR_ACCOUNT>') THEN
    RAISE wrong_account;
  END IF;
  RETURN 'Demo account confirmed';
END;
$$;

-- 1. Compute: stop any running jobs, then drop the dedicated GPU pool.
ALTER COMPUTE POOL IF EXISTS KUMO_DEMO_GPU_POOL STOP ALL;
DROP COMPUTE POOL IF EXISTS KUMO_DEMO_GPU_POOL;

-- 2. Data and everything in it: RAW tables, governed views, semantic view,
--    SQL procedures, Model Registry model, experiment, job stage and results.
DROP DATABASE IF EXISTS KUMO_SEMANTIC_DEMO;
-- Scratch database used only to validate the SQL generator.
DROP DATABASE IF EXISTS KUMO_GEN_VALIDATE;

-- 3. Account-level objects.
DROP EXTERNAL ACCESS INTEGRATION IF EXISTS KUMO_DEMO_PYPI_EAI;
DROP WAREHOUSE IF EXISTS KUMO_DEMO_WH;

-- 4. Roles, last, after the objects they owned are gone.
DROP ROLE IF EXISTS KUMO_DEMO_READER;
DROP ROLE IF EXISTS KUMO_DEMO_ML;
DROP ROLE IF EXISTS KUMO_DEMO_IDENTITY_STEWARD;
DROP ROLE IF EXISTS KUMO_DEMO_OWNER;

-- Verify: every count should be 0.
SHOW DATABASES LIKE 'KUMO_%';
SHOW COMPUTE POOLS LIKE 'KUMO_DEMO_%';
SHOW WAREHOUSES LIKE 'KUMO_DEMO_%';
SHOW INTEGRATIONS LIKE 'KUMO_DEMO_%';
SHOW ROLES LIKE 'KUMO_DEMO_%';

-- Install as OWNER after explicit deployment approval. All procedures execute
-- as CALLER: none can lend OWNER's RAW access to the ML runtime.
USE ROLE KUMO_DEMO_OWNER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE KUMO_DEMO_WH;
USE DATABASE KUMO_SEMANTIC_DEMO;
USE SCHEMA RESULTS;

CREATE TABLE V2_CONFIG (
  config_id VARCHAR, fit_cutoff TIMESTAMP_NTZ, holdout_anchor TIMESTAMP_NTZ,
  score_anchor TIMESTAMP_NTZ, seed NUMBER, max_rows NUMBER, contract_version VARCHAR);
INSERT INTO V2_CONFIG VALUES ('RETAIL_V2','2026-04-01','2026-05-31','2026-06-30 23:59:59',42,1000000,'sql-v2');
CREATE TABLE V2_ANCHORS (anchor TIMESTAMP_NTZ, split NUMBER);
INSERT INTO V2_ANCHORS VALUES
 ('2025-04-01',0),('2025-05-01',0),('2025-06-01',0),('2025-07-01',0),
 ('2025-08-01',0),('2025-09-01',0),('2025-10-01',0),('2025-11-01',0),
 ('2026-01-01',1),('2026-03-01',2);
-- Independent security contract; this table does NOT define graph relationships.
CREATE TABLE V2_ALLOWED_COLUMNS (table_name VARCHAR, column_name VARCHAR, primary_key VARCHAR, time_column VARCHAR);
INSERT INTO V2_ALLOWED_COLUMNS VALUES
 ('CUSTOMERS','CUSTOMER_ID','CUSTOMER_ID','JOINED_AT'),('CUSTOMERS','REGION','CUSTOMER_ID','JOINED_AT'),
 ('CUSTOMERS','ACQUISITION_CHANNEL','CUSTOMER_ID','JOINED_AT'),('CUSTOMERS','JOINED_AT','CUSTOMER_ID','JOINED_AT'),
 ('ORDERS','ORDER_ID','ORDER_ID','ORDERED_AT'),('ORDERS','CUSTOMER_ID','ORDER_ID','ORDERED_AT'),
 ('ORDERS','ORDERED_AT','ORDER_ID','ORDERED_AT'),('ORDERS','CHANNEL','ORDER_ID','ORDERED_AT'),
 ('ORDERS','ORDER_TOTAL','ORDER_ID','ORDERED_AT'),
 ('ORDER_ITEMS','ITEM_ID','ITEM_ID','ORDERED_AT'),('ORDER_ITEMS','ORDER_ID','ITEM_ID','ORDERED_AT'),
 ('ORDER_ITEMS','PRODUCT_ID','ITEM_ID','ORDERED_AT'),('ORDER_ITEMS','ORDERED_AT','ITEM_ID','ORDERED_AT'),
 ('ORDER_ITEMS','QUANTITY','ITEM_ID','ORDERED_AT'),('ORDER_ITEMS','UNIT_PRICE','ITEM_ID','ORDERED_AT'),
 ('ORDER_ITEMS','LINE_TOTAL','ITEM_ID','ORDERED_AT'),
 ('PRODUCTS','PRODUCT_ID','PRODUCT_ID',NULL),('PRODUCTS','CATEGORY','PRODUCT_ID',NULL),
 ('PRODUCTS','LIST_PRICE','PRODUCT_ID',NULL);
CREATE TABLE V2_RUNS (
 run_id VARCHAR, status VARCHAR, dataset_revision VARCHAR, semantic_hash VARCHAR,
 manifest VARIANT, config VARIANT, model_name VARCHAR, model_version VARCHAR,
 started_at TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(), completed_at TIMESTAMP_LTZ);
CREATE TABLE V2_BATCHES (run_id VARCHAR,batch VARCHAR,anchor TIMESTAMP_NTZ,seed_table VARCHAR,
 raw_table VARCHAR,result_table VARCHAR,status VARCHAR,row_count NUMBER,metrics VARIANT);
GRANT SELECT ON TABLE V2_CONFIG TO ROLE KUMO_DEMO_ML;
GRANT SELECT ON TABLE V2_ANCHORS TO ROLE KUMO_DEMO_ML;
GRANT SELECT ON TABLE V2_ALLOWED_COLUMNS TO ROLE KUMO_DEMO_ML;
GRANT SELECT, INSERT, UPDATE ON TABLE V2_RUNS TO ROLE KUMO_DEMO_ML;
GRANT SELECT, INSERT, UPDATE ON TABLE V2_BATCHES TO ROLE KUMO_DEMO_ML;

CREATE PROCEDURE V2_ASSERT_IDENTITY(expected_account VARCHAR)
RETURNS VARCHAR LANGUAGE SQL EXECUTE AS CALLER AS $$
DECLARE denied EXCEPTION (-20010,'Incorrect account, role, warehouse or inherited privileged role');
BEGIN
  IF (expected_account IS NULL OR CURRENT_ACCOUNT_NAME() <> expected_account
      OR CURRENT_ROLE() <> 'KUMO_DEMO_ML' OR CURRENT_WAREHOUSE() IS NULL
      OR IS_ROLE_IN_SESSION('KUMO_DEMO_OWNER') OR IS_ROLE_IN_SESSION('KUMO_DEMO_IDENTITY_STEWARD')) THEN
    RAISE denied;
  END IF;
  RETURN 'PASS';
END;
$$;
GRANT USAGE ON PROCEDURE V2_ASSERT_IDENTITY(VARCHAR) TO ROLE KUMO_DEMO_ML;

CREATE PROCEDURE V2_RAW_DENIAL(expected_account VARCHAR)
RETURNS VARCHAR LANGUAGE SQL EXECUTE AS CALLER AS $$
DECLARE
  failure EXCEPTION (-20011,'RAW access unexpectedly succeeded');
  target VARCHAR; n NUMBER; denied BOOLEAN;
  raw_tables ARRAY DEFAULT ARRAY_CONSTRUCT('CUSTOMERS','CUSTOMER_IDENTITY','ORDERS','ORDER_ITEMS','PRODUCTS');
BEGIN
  CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_ASSERT_IDENTITY(:expected_account);
  FOR i IN 0 TO ARRAY_SIZE(raw_tables)-1 DO
    target := 'KUMO_SEMANTIC_DEMO.RAW.' || raw_tables[i]::VARCHAR;
    denied := FALSE;
    BEGIN
      SELECT COUNT(*) INTO :n FROM (SELECT 1 FROM IDENTIFIER(:target) LIMIT 1);
    EXCEPTION WHEN STATEMENT_ERROR THEN
      IF (ABS(SQLCODE) IN (2003,3001)) THEN denied := TRUE; ELSE RAISE; END IF;
    END;
    IF (NOT denied) THEN RAISE failure; END IF;
  END FOR;
  RETURN 'DENIED';
END;
$$;
GRANT USAGE ON PROCEDURE V2_RAW_DENIAL(VARCHAR) TO ROLE KUMO_DEMO_ML;

CREATE PROCEDURE V2_MANIFEST(expected_account VARCHAR, cutoff TIMESTAMP_NTZ)
RETURNS VARIANT LANGUAGE SQL EXECUTE AS CALLER AS $$
DECLARE
  invalid EXCEPTION (-20012,'Unsupported or changed semantic/input contract');
  query_id VARCHAR; yaml_text VARCHAR; semantic_hash VARCHAR;
  tables ARRAY; edges ARRAY; n NUMBER; count_check NUMBER;
BEGIN
  CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_ASSERT_IDENTITY(:expected_account);
  SELECT SYSTEM$READ_YAML_FROM_SEMANTIC_VIEW('KUMO_SEMANTIC_DEMO.SEMANTIC.RETAIL_CUSTOMER_360') INTO :yaml_text;
  -- Conservative supplementary guard for constructs not represented by DESC.
  -- The v2 authoring contract is intentionally narrower than arbitrary YAML.
  IF (yaml_text IS NULL OR LENGTH(yaml_text)>1000000 OR
      REGEXP_INSTR(yaml_text,'(^|\n)[ ]*(filters|constraints|variables|sample_values|labels|sql|query|relationship_type|join_type)[ ]*:',1,1,0,'im')>0) THEN
    RAISE invalid;
  END IF;
  semantic_hash := SHA2('sql-v2-yaml-bytes:' || yaml_text,256);
  DESCRIBE SEMANTIC VIEW KUMO_SEMANTIC_DEMO.SEMANTIC.RETAIL_CUSTOMER_360;
  query_id := SQLID;
  CREATE OR REPLACE TEMP TABLE KUMO_SEMANTIC_DEMO.RESULTS.V2_META AS
    SELECT "object_kind" kind,"object_name" name,"parent_entity" parent,
      "property" property,"property_value" value FROM TABLE(RESULT_SCAN(:query_id));
  SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META
    WHERE kind IS NOT NULL AND kind NOT IN ('TABLE','RELATIONSHIP','DIMENSION','FACT','METRIC')
      -- Cortex Analyst name index only; it adds no tables, joins or expressions.
      AND NOT (kind='EXTENSION' AND name='CA' AND property='VALUE');
  IF (n<>0) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM (
    SELECT kind,name,parent,property,COUNT(*) n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META
    GROUP BY kind,name,parent,property HAVING COUNT(*)>1);
  IF (n<>0) THEN RAISE invalid; END IF;
  CREATE OR REPLACE TEMP TABLE KUMO_SEMANTIC_DEMO.RESULTS.V2_META_TABLES AS
    SELECT name,MAX(IFF(property='BASE_TABLE_DATABASE_NAME',value,NULL)) db,
      MAX(IFF(property='BASE_TABLE_SCHEMA_NAME',value,NULL)) schema_name,
      MAX(IFF(property='BASE_TABLE_NAME',value,NULL)) source,
      TRY_PARSE_JSON(MAX(IFF(property='PRIMARY_KEY',value,NULL))) pk,
      MAX(IFF(property='DEFINITION',value,NULL)) definition
    FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META WHERE kind='TABLE' GROUP BY name;
  SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META_TABLES t
    WHERE db IS NULL OR db<>'KUMO_SEMANTIC_DEMO' OR schema_name IS NULL OR schema_name<>'GOVERNED'
      OR source IS NULL OR source<>name OR name NOT IN ('CUSTOMERS','ORDERS','ORDER_ITEMS','PRODUCTS')
      OR definition IS NOT NULL OR pk IS NULL OR NOT IS_ARRAY(pk) OR ARRAY_SIZE(pk)<>1
      OR pk[0]::VARCHAR <> (SELECT MAX(a.primary_key) FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_ALLOWED_COLUMNS a WHERE a.table_name=t.name);
  SELECT COUNT(*) INTO :count_check FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META_TABLES;
  IF (n<>0 OR count_check<>4) THEN RAISE invalid; END IF;
  CREATE OR REPLACE TEMP TABLE KUMO_SEMANTIC_DEMO.RESULTS.V2_META_COLUMNS AS
    SELECT kind,parent,name,
      MAX(IFF(property='EXPRESSION',value,NULL)) expression,
      MAX(IFF(property='DATA_TYPE',value,NULL)) data_type,
      MAX(IFF(property='ACCESS_MODIFIER',value,NULL)) access_modifier
    FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META WHERE kind IN ('DIMENSION','FACT') GROUP BY kind,parent,name;
  SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META_COLUMNS c
    FULL OUTER JOIN KUMO_SEMANTIC_DEMO.RESULTS.V2_ALLOWED_COLUMNS a ON c.parent=a.table_name AND c.name=a.column_name
    WHERE c.name IS NULL OR a.column_name IS NULL OR c.expression IS NULL
      OR UPPER(REPLACE(c.expression,'"','')) NOT IN (c.name,c.parent||'.'||c.name)
      OR c.data_type IS NULL OR c.access_modifier IS NULL OR c.access_modifier<>'PUBLIC'
      OR (c.name=a.time_column AND c.data_type NOT LIKE 'TIMESTAMP_NTZ%');
  SELECT COUNT(*) INTO :count_check FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META_COLUMNS;
  IF (n<>0 OR count_check<>19) THEN RAISE invalid; END IF;
  -- Actual view schema must also match the independent column contract.
  SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_ALLOWED_COLUMNS a
    FULL OUTER JOIN (SELECT table_name,column_name FROM KUMO_SEMANTIC_DEMO.INFORMATION_SCHEMA.COLUMNS
      WHERE table_schema='GOVERNED' AND table_name IN ('CUSTOMERS','ORDERS','ORDER_ITEMS','PRODUCTS')) c
    ON a.table_name=c.table_name AND a.column_name=c.column_name
    WHERE a.column_name IS NULL OR c.column_name IS NULL;
  IF (n<>0) THEN RAISE invalid; END IF;
  CREATE OR REPLACE TEMP TABLE KUMO_SEMANTIC_DEMO.RESULTS.V2_META_EDGES AS
    SELECT name,MAX(IFF(property='TABLE',value,NULL)) source,
      MAX(IFF(property='REF_TABLE',value,NULL)) destination,
      TRY_PARSE_JSON(MAX(IFF(property='FOREIGN_KEY',value,NULL))) fk,
      TRY_PARSE_JSON(MAX(IFF(property='REF_KEY',value,NULL))) ref_key
    FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META WHERE kind='RELATIONSHIP' GROUP BY name;
  SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META_EDGES e
    LEFT JOIN KUMO_SEMANTIC_DEMO.RESULTS.V2_META_TABLES t ON t.name=e.destination
    LEFT JOIN KUMO_SEMANTIC_DEMO.RESULTS.V2_ALLOWED_COLUMNS c ON c.table_name=e.source AND c.column_name=e.fk[0]::VARCHAR
    WHERE NOT REGEXP_LIKE(e.name,'[A-Z][A-Z0-9_]*') OR e.source IS NULL OR e.destination IS NULL
      OR e.source=e.destination OR t.name IS NULL OR c.column_name IS NULL
      OR e.fk IS NULL OR e.ref_key IS NULL OR NOT IS_ARRAY(e.fk) OR NOT IS_ARRAY(e.ref_key)
      OR ARRAY_SIZE(e.fk)<>1 OR ARRAY_SIZE(e.ref_key)<>1 OR e.ref_key[0]<>t.pk[0];
  SELECT COUNT(*) INTO :count_check FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META_EDGES;
  IF (n<>0 OR count_check=0) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM (SELECT source,destination,fk FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META_EDGES
    GROUP BY source,destination,fk HAVING COUNT(*)>1);
  IF (n<>0) THEN RAISE invalid; END IF;
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT('name',name,'source',source,'destination',destination,
    'foreign_key',fk[0]::VARCHAR,'primary_key',ref_key[0]::VARCHAR)) WITHIN GROUP (ORDER BY name)
    INTO :edges FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META_EDGES;
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL('alias',t.name,'source',t.source,'primary_key',t.pk[0]::VARCHAR,
    'time_column',c.time_column,'columns',c.columns,'categorical_columns',c.categories,
    'source_sql','SELECT '||c.projection||' FROM "KUMO_SEMANTIC_DEMO"."GOVERNED"."'||t.source||'"'
      ||' WHERE CURRENT_ROLE() = ''KUMO_DEMO_ML'' AND NOT IS_ROLE_IN_SESSION(''KUMO_DEMO_OWNER'')'
      ||' AND NOT IS_ROLE_IN_SESSION(''KUMO_DEMO_IDENTITY_STEWARD'')'
      ||IFF(c.time_column IS NULL OR :cutoff IS NULL,'',' AND "'||c.time_column||'" <= '''||TO_CHAR(:cutoff,'YYYY-MM-DD"T"HH24:MI:SS.FF9')||'''::TIMESTAMP_NTZ')))
    WITHIN GROUP (ORDER BY t.name) INTO :tables
    FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META_TABLES t JOIN (
      SELECT c.parent,MAX(a.time_column) time_column,ARRAY_AGG(c.name) WITHIN GROUP (ORDER BY c.name) columns,
        ARRAY_COMPACT(ARRAY_AGG(IFF(c.data_type LIKE 'VARCHAR%',c.name,NULL)) WITHIN GROUP (ORDER BY c.name)) categories,
        LISTAGG(IFF(RIGHT(c.name,3)='_ID','CAST("'||c.name||'" AS VARCHAR) AS "'||c.name||'"',
          '"'||c.name||'"'),', ') WITHIN GROUP (ORDER BY c.name) projection
      FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_META_COLUMNS c JOIN KUMO_SEMANTIC_DEMO.RESULTS.V2_ALLOWED_COLUMNS a
      ON a.table_name=c.parent AND a.column_name=c.name GROUP BY c.parent) c ON c.parent=t.name;
  RETURN OBJECT_CONSTRUCT('contract_version','sql-v2','hash_version','sql-v2-yaml-bytes',
    'semantic_hash',semantic_hash,'tables',tables,'relationships',edges);
END;
$$;
GRANT USAGE ON PROCEDURE V2_MANIFEST(VARCHAR,TIMESTAMP_NTZ) TO ROLE KUMO_DEMO_ML;

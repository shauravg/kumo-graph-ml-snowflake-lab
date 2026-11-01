USE ROLE KUMO_DEMO_OWNER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE KUMO_DEMO_WH;
USE DATABASE KUMO_SEMANTIC_DEMO;
USE SCHEMA RESULTS;

CREATE PROCEDURE V2_CHECK_DATA(expected_account VARCHAR, cutoff TIMESTAMP_NTZ)
RETURNS VARCHAR LANGUAGE SQL EXECUTE AS CALLER AS $$
DECLARE
  invalid EXCEPTION (-20020,'Input integrity, size, time or revenue check failed');
  manifest VARIANT; target VARCHAR; key_name VARCHAR; time_name VARCHAR;
  n NUMBER; bad NUMBER; maximum_rows NUMBER; header_total NUMBER(38,2); line_total NUMBER(38,2);
BEGIN
  CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_ASSERT_IDENTITY(:expected_account);
  CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_RAW_DENIAL(:expected_account);
  CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_MANIFEST(:expected_account,:cutoff) INTO :manifest;
  SELECT max_rows INTO :maximum_rows FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_CONFIG WHERE config_id='RETAIL_V2';
  FOR i IN 0 TO ARRAY_SIZE(manifest:tables)-1 DO
    target := 'KUMO_SEMANTIC_DEMO.GOVERNED.'||manifest:tables[i]:source::VARCHAR;
    key_name := manifest:tables[i]:primary_key::VARCHAR;
    time_name := manifest:tables[i]:time_column::VARCHAR;
    SELECT COUNT(*),COUNT(*)-COUNT(DISTINCT IDENTIFIER(:key_name)) INTO :n,:bad FROM IDENTIFIER(:target);
    IF (n=0 OR n>maximum_rows OR bad<>0) THEN RAISE invalid; END IF;
    -- Kumo receives keys as strings (it rejects float graph keys); require exact integers.
    SELECT COUNT(*) INTO :bad FROM IDENTIFIER(:target)
      WHERE ABS(IDENTIFIER(:key_name))>9007199254740991
        OR IDENTIFIER(:key_name)<>TRUNC(IDENTIFIER(:key_name));
    IF (bad<>0) THEN RAISE invalid; END IF;
    IF (time_name IS NOT NULL) THEN
      SELECT COUNT(*) INTO :bad FROM IDENTIFIER(:target) WHERE IDENTIFIER(:time_name) IS NULL;
      IF (bad<>0) THEN RAISE invalid; END IF;
    END IF;
  END FOR;
  SELECT COUNT(*) INTO :bad FROM KUMO_SEMANTIC_DEMO.GOVERNED.ORDERS o
    LEFT JOIN KUMO_SEMANTIC_DEMO.GOVERNED.CUSTOMERS c ON c.customer_id=o.customer_id
    WHERE c.customer_id IS NULL OR o.ordered_at<c.joined_at;
  IF (bad<>0) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :bad FROM KUMO_SEMANTIC_DEMO.GOVERNED.ORDER_ITEMS i
    LEFT JOIN KUMO_SEMANTIC_DEMO.GOVERNED.ORDERS o ON o.order_id=i.order_id
    LEFT JOIN KUMO_SEMANTIC_DEMO.GOVERNED.PRODUCTS p ON p.product_id=i.product_id
    WHERE o.order_id IS NULL OR p.product_id IS NULL OR i.ordered_at<>o.ordered_at
      OR i.quantity IS NULL OR i.quantity<=0 OR i.unit_price IS NULL OR i.unit_price<0
      OR i.line_total IS NULL OR ABS(i.line_total-i.quantity*i.unit_price)>0.01;
  IF (bad<>0) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :bad FROM KUMO_SEMANTIC_DEMO.GOVERNED.ORDERS o
    LEFT JOIN (SELECT order_id,SUM(line_total) total FROM KUMO_SEMANTIC_DEMO.GOVERNED.ORDER_ITEMS GROUP BY order_id) i
    ON i.order_id=o.order_id WHERE i.total IS NULL OR o.order_total IS NULL OR ABS(i.total-o.order_total)>0.01;
  IF (bad<>0) THEN RAISE invalid; END IF;
  -- Audit every semantic edge, not just the canonical data relationships above.
  FOR j IN 0 TO ARRAY_SIZE(manifest:relationships)-1 DO
    LET source_name VARCHAR := 'KUMO_SEMANTIC_DEMO.GOVERNED.'||manifest:relationships[j]:source::VARCHAR;
    LET destination_name VARCHAR := 'KUMO_SEMANTIC_DEMO.GOVERNED.'||manifest:relationships[j]:destination::VARCHAR;
    LET fk VARCHAR := manifest:relationships[j]:foreign_key::VARCHAR;
    LET pk VARCHAR := manifest:relationships[j]:primary_key::VARCHAR;
    SELECT COUNT(*) INTO :bad FROM
      (SELECT IDENTIFIER(:fk) k FROM IDENTIFIER(:source_name)) s
      LEFT JOIN (SELECT IDENTIFIER(:pk) k FROM IDENTIFIER(:destination_name)) d ON s.k=d.k
      WHERE d.k IS NULL;
    IF (bad<>0) THEN RAISE invalid; END IF;
  END FOR;
  SELECT sales INTO :header_total FROM SEMANTIC_VIEW(KUMO_SEMANTIC_DEMO.SEMANTIC.RETAIL_CUSTOMER_360 METRICS ORDERS.SALES);
  SELECT item_sales INTO :line_total FROM SEMANTIC_VIEW(KUMO_SEMANTIC_DEMO.SEMANTIC.RETAIL_CUSTOMER_360 METRICS ORDER_ITEMS.ITEM_SALES);
  SELECT COUNT(*) INTO :bad FROM (SELECT SUM(order_total) total FROM KUMO_SEMANTIC_DEMO.GOVERNED.ORDERS)
    WHERE total IS NULL OR ABS(total-:header_total)>0.01 OR ABS(total-:line_total)>0.01;
  IF (bad<>0 OR header_total IS NULL OR line_total IS NULL) THEN RAISE invalid; END IF;
  RETURN 'PASS';
END;
$$;
GRANT USAGE ON PROCEDURE V2_CHECK_DATA(VARCHAR,TIMESTAMP_NTZ) TO ROLE KUMO_DEMO_ML;

CREATE PROCEDURE V2_PREPARE(expected_account VARCHAR, reviewed_hash VARCHAR, dataset_revision VARCHAR)
RETURNS VARIANT LANGUAGE SQL EXECUTE AS CALLER AS $$
DECLARE
  invalid EXCEPTION (-20021,'Invalid configuration, metadata hash, source history or training rows');
  run_id VARCHAR; manifest VARIANT; config VARIANT; n NUMBER; split_count NUMBER; fit_cutoff TIMESTAMP_NTZ;
  holdout_anchor TIMESTAMP_NTZ; score_anchor TIMESTAMP_NTZ;
  population_name VARCHAR; training_name VARCHAR; seed_name VARCHAR; raw_name VARCHAR; result_name VARCHAR;
BEGIN
  CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_ASSERT_IDENTITY(:expected_account);
  IF (dataset_revision IS NULL OR LENGTH(dataset_revision)=0 OR reviewed_hash IS NULL) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_CONFIG;
  IF (n<>1) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_CONFIG
    WHERE config_id IS NULL OR config_id<>'RETAIL_V2' OR contract_version IS NULL OR contract_version<>'sql-v2'
      OR seed IS NULL OR max_rows IS NULL OR max_rows<1 OR max_rows>1000000;
  IF (n<>0) THEN RAISE invalid; END IF;
  SELECT fit_cutoff,holdout_anchor,score_anchor,
    OBJECT_CONSTRUCT('fit_cutoff',TO_CHAR(fit_cutoff,'YYYY-MM-DD"T"HH24:MI:SS'),
    'holdout_anchor',TO_CHAR(holdout_anchor,'YYYY-MM-DD"T"HH24:MI:SS'),
    'score_anchor',TO_CHAR(score_anchor,'YYYY-MM-DD"T"HH24:MI:SS'),'seed',seed,'max_rows',max_rows,
    'pql','PREDICT COUNT(ORDERS.*, 0, 30, days) > 0 FOR EACH CUSTOMERS.CUSTOMER_ID WHERE COUNT(ORDERS.*, -90, 0, days) > 0')
    INTO :fit_cutoff,:holdout_anchor,:score_anchor,:config
    FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_CONFIG WHERE config_id='RETAIL_V2';
  IF (fit_cutoff IS NULL OR holdout_anchor IS NULL OR score_anchor IS NULL
      OR fit_cutoff>=holdout_anchor OR holdout_anchor>=score_anchor) THEN RAISE invalid; END IF;
  CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_CHECK_DATA(:expected_account,:fit_cutoff);
  CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_MANIFEST(:expected_account,:fit_cutoff) INTO :manifest;
  IF (manifest:semantic_hash::VARCHAR<>reviewed_hash) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_ANCHORS
    WHERE anchor IS NULL OR split IS NULL OR split NOT IN (0,1,2) OR DATEADD(day,30,anchor)>:fit_cutoff;
  IF (n<>0) THEN RAISE invalid; END IF;
  SELECT COUNT(*)-COUNT(DISTINCT anchor) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_ANCHORS;
  SELECT COUNT(DISTINCT split) INTO :split_count FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_ANCHORS;
  IF (n<>0 OR split_count<>3) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM (
    SELECT split,MAX(anchor) last_anchor,LEAD(MIN(anchor)) OVER (ORDER BY split) next_anchor
    FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_ANCHORS GROUP BY split)
    WHERE DATEADD(day,30,last_anchor)>=next_anchor;
  IF (n<>0) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM (SELECT MAX(ordered_at) last_event FROM KUMO_SEMANTIC_DEMO.GOVERNED.ORDERS)
    WHERE last_event IS NULL OR last_event<DATEADD(day,30,:holdout_anchor) OR last_event>:score_anchor;
  IF (n<>0) THEN RAISE invalid; END IF;
  run_id := 'RUN_'||REPLACE(UPPER(UUID_STRING()),'-','');
  population_name := 'KUMO_SEMANTIC_DEMO.RESULTS.V2_POPULATION_'||run_id;
  training_name := 'KUMO_SEMANTIC_DEMO.RESULTS.V2_TRAIN_'||run_id;
  INSERT INTO KUMO_SEMANTIC_DEMO.RESULTS.V2_RUNS(run_id,status,dataset_revision,semantic_hash,manifest,config)
    SELECT :run_id,'PREPARING',:dataset_revision,:reviewed_hash,:manifest,:config;
  -- No mutable real-world dimensions: customer/product attributes are static in this demo.
  CREATE TABLE IDENTIFIER(:population_name) AS
  WITH anchors AS (
    SELECT anchor,split,'TRAIN' batch FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_ANCHORS
    UNION ALL SELECT :holdout_anchor,NULL,'HOLDOUT'
    UNION ALL SELECT :score_anchor,NULL,'CURRENT'
  ), counts AS (
    SELECT c.customer_id entity1,a.anchor timestamp,a.split,a.batch,
      COUNT_IF(o.ordered_at>DATEADD(day,-90,a.anchor) AND o.ordered_at<=a.anchor) prior_count,
      COUNT_IF(o.ordered_at>a.anchor AND o.ordered_at<=DATEADD(day,30,a.anchor)) future_count
    FROM KUMO_SEMANTIC_DEMO.GOVERNED.CUSTOMERS c CROSS JOIN anchors a
    LEFT JOIN KUMO_SEMANTIC_DEMO.GOVERNED.ORDERS o ON o.customer_id=c.customer_id
      AND o.ordered_at>DATEADD(day,-90,a.anchor)
      AND o.ordered_at<=IFF(a.batch='CURRENT',a.anchor,DATEADD(day,30,a.anchor))
    WHERE c.joined_at<=a.anchor
    GROUP BY c.customer_id,a.anchor,a.split,a.batch
  )
  SELECT entity1,timestamp,split,batch,IFF(batch='CURRENT',NULL,COALESCE(future_count,0)>0) target1,
    (1-EXP(-prior_count/3.0))::DOUBLE baseline_prob FROM counts WHERE prior_count>0;
  SELECT COUNT(*) INTO :n FROM (SELECT split,COUNT(DISTINCT target1) classes
    FROM IDENTIFIER(:population_name) WHERE batch='TRAIN' GROUP BY split) WHERE classes<>2;
  SELECT COUNT(DISTINCT split) INTO :split_count FROM IDENTIFIER(:population_name) WHERE batch='TRAIN';
  IF (n<>0 OR split_count<>3) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM IDENTIFIER(:population_name) WHERE batch='TRAIN';
  IF (n>config:max_rows::NUMBER) THEN RAISE invalid; END IF;
  CREATE TABLE IDENTIFIER(:training_name) AS
    SELECT entity1::VARCHAR entity1,timestamp,target1,split::DOUBLE split FROM IDENTIFIER(:population_name) WHERE batch='TRAIN';
  FOR b IN 0 TO 1 DO
    LET batch_name VARCHAR := ARRAY_CONSTRUCT('HOLDOUT','CURRENT')[b]::VARCHAR;
    seed_name := 'KUMO_SEMANTIC_DEMO.RESULTS.V2_SEEDS_'||batch_name||'_'||run_id;
    raw_name := 'KUMO_SEMANTIC_DEMO.RESULTS.KUMO_'||batch_name||'_'||run_id;
    result_name := 'KUMO_SEMANTIC_DEMO.RESULTS.RETAIL_'||batch_name||'_'||run_id;
    SELECT COUNT(*) INTO :n FROM IDENTIFIER(:population_name) WHERE batch=:batch_name;
    IF (n=0 OR n>config:max_rows::NUMBER) THEN RAISE invalid; END IF;
    CREATE TABLE IDENTIFIER(:seed_name) AS SELECT entity1::VARCHAR entity1,timestamp FROM IDENTIFIER(:population_name) WHERE batch=:batch_name;
    INSERT INTO KUMO_SEMANTIC_DEMO.RESULTS.V2_BATCHES
      SELECT :run_id,:batch_name,IFF(:batch_name='HOLDOUT',:holdout_anchor,:score_anchor),
        :seed_name,:raw_name,:result_name,'PREPARED',:n,NULL;
  END FOR;
  UPDATE KUMO_SEMANTIC_DEMO.RESULTS.V2_RUNS SET status='PREPARED' WHERE run_id=:run_id;
  RETURN OBJECT_CONSTRUCT('run_id',run_id,'manifest',manifest,'config',config,
    'training_table',training_name,'population_table',population_name);
END;
$$;
GRANT USAGE ON PROCEDURE V2_PREPARE(VARCHAR,VARCHAR,VARCHAR) TO ROLE KUMO_DEMO_ML;

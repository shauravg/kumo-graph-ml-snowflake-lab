USE ROLE KUMO_DEMO_OWNER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE KUMO_DEMO_WH;
USE DATABASE KUMO_SEMANTIC_DEMO;
USE SCHEMA RESULTS;

CREATE PROCEDURE V2_EVALUATE(expected_account VARCHAR, holdout_table VARCHAR)
RETURNS VARIANT LANGUAGE SQL EXECUTE AS CALLER AS $$
DECLARE
  invalid EXCEPTION (-20030,'Empty, duplicated or invalid holdout rows');
  n NUMBER; metrics ARRAY; calibration ARRAY; lift ARRAY;
BEGIN
  CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_ASSERT_IDENTITY(:expected_account);
  IF (holdout_table IS NULL OR NOT REGEXP_LIKE(holdout_table,'KUMO_SEMANTIC_DEMO[.]RESULTS[.][A-Z][A-Z0-9_]*')) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM IDENTIFIER(:holdout_table);
  IF (n=0) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM IDENTIFIER(:holdout_table)
    WHERE entity1 IS NULL OR timestamp IS NULL OR target1 IS NULL
      OR probability IS NULL OR NOT probability BETWEEN 0 AND 1
      OR baseline_prob IS NULL OR NOT baseline_prob BETWEEN 0 AND 1;
  IF (n<>0) THEN RAISE invalid; END IF;
  SELECT COUNT(*) INTO :n FROM (SELECT entity1,timestamp FROM IDENTIFIER(:holdout_table)
    GROUP BY entity1,timestamp HAVING COUNT(*)<>1);
  IF (n<>0) THEN RAISE invalid; END IF;
  CREATE OR REPLACE TEMP TABLE KUMO_SEMANTIC_DEMO.RESULTS.V2_SCORES AS
    SELECT 'kumo' model,target1::INTEGER label,probability::DOUBLE score FROM IDENTIFIER(:holdout_table)
    UNION ALL SELECT 'baseline',target1::INTEGER,baseline_prob::DOUBLE FROM IDENTIFIER(:holdout_table);
  -- Group equal scores BEFORE cumulative precision/ranking; tie order cannot change AP.
  WITH grouped AS (
    SELECT model,score,SUM(label) positives,COUNT(*) samples,SUM(POWER(score-label,2)) error
    FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_SCORES GROUP BY model,score
  ), ranked AS (
    SELECT *,SUM(samples) OVER (PARTITION BY model) total,
      SUM(positives) OVER (PARTITION BY model) total_positive,
      SUM(samples) OVER (PARTITION BY model ORDER BY score DESC ROWS UNBOUNDED PRECEDING) cumulative_n,
      SUM(positives) OVER (PARTITION BY model ORDER BY score DESC ROWS UNBOUNDED PRECEDING) cumulative_positive
    FROM grouped
  ), per_model AS (
    SELECT model,MAX(total) row_count,MAX(total_positive)/MAX(total) positive_rate,
      SUM(positives*(total-cumulative_n+(samples+1)/2.0)) positive_rank_sum,
      MAX(total_positive) total_positive,
      SUM(positives*cumulative_positive/cumulative_n)/NULLIF(MAX(total_positive),0) average_precision,
      SUM(error)/MAX(total) brier,
      SUM(IFF(cumulative_n-samples<CEIL(total/10.0),positives,0)) top_positive,
      SUM(IFF(cumulative_n-samples<CEIL(total/10.0),samples,0)) top_n
    FROM ranked GROUP BY model
  )
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL('model',model,'rows',row_count,'positive_rate',positive_rate,
    'auroc',(positive_rank_sum-total_positive*(total_positive+1)/2.0)/NULLIF(total_positive*(row_count-total_positive),0),
    'average_precision',average_precision,'brier',brier,
    'top_decile_lift',(top_positive/NULLIF(top_n,0))/NULLIF(positive_rate,0),
    'top_decile_selected_fraction',top_n/row_count)) WITHIN GROUP (ORDER BY model)
    INTO :metrics FROM per_model;
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT('model',model,'bin',bin,'count',n,'mean_score',mean_score,'observed_rate',observed_rate))
    WITHIN GROUP (ORDER BY model,bin) INTO :calibration FROM (
      SELECT model,LEAST(FLOOR(score*10),9) bin,COUNT(*) n,AVG(score) mean_score,AVG(label) observed_rate
      FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_SCORES GROUP BY model,bin);
  WITH grouped AS (
    SELECT model,score,SUM(label) positives,COUNT(*) samples FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_SCORES GROUP BY model,score
  ), ranked AS (
    SELECT *,SUM(samples) OVER (PARTITION BY model) total,SUM(positives) OVER (PARTITION BY model) total_positive,
      SUM(samples) OVER (PARTITION BY model ORDER BY score DESC ROWS UNBOUNDED PRECEDING)-samples ahead FROM grouped
  ), fractions AS (SELECT column1 fraction FROM VALUES (0.1),(0.2),(0.3),(0.4),(0.5),(0.6),(0.7),(0.8),(0.9),(1.0)),
  selected AS (
    SELECT model,fraction,SUM(samples)/MAX(total) selected_fraction,
      (SUM(positives)/SUM(samples))/NULLIF(MAX(total_positive)/MAX(total),0) lift
    FROM ranked CROSS JOIN fractions WHERE ahead<CEIL(total*fraction) GROUP BY model,fraction
  )
  SELECT ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL('model',model,'fraction',fraction,'selected_fraction',selected_fraction,'lift',lift))
    WITHIN GROUP (ORDER BY model,fraction) INTO :lift FROM selected;
  RETURN OBJECT_CONSTRUCT('metrics',metrics,'calibration',calibration,'cumulative_lift',lift);
END;
$$;
GRANT USAGE ON PROCEDURE V2_EVALUATE(VARCHAR,VARCHAR) TO ROLE KUMO_DEMO_ML;

CREATE PROCEDURE V2_FINALIZE(expected_account VARCHAR, requested_run VARCHAR, requested_batch VARCHAR)
RETURNS VARIANT LANGUAGE SQL EXECUTE AS CALLER AS $$
DECLARE
 invalid EXCEPTION (-20031,'Prediction population, probabilities, state or write-back invalid');
 raw_name VARCHAR; result_name VARCHAR; population_name VARCHAR; version VARCHAR; fingerprint VARCHAR;
 expected_n NUMBER; n NUMBER; metrics VARIANT; summary VARIANT;
BEGIN
 CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_ASSERT_IDENTITY(:expected_account);
 IF (requested_run IS NULL OR NOT REGEXP_LIKE(requested_run,'RUN_[A-F0-9]{32}')
   OR requested_batch IS NULL OR requested_batch NOT IN ('HOLDOUT','CURRENT')) THEN RAISE invalid; END IF;
 SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_BATCHES
   WHERE run_id=:requested_run AND batch=:requested_batch AND status='PREPARED';
 IF (n<>1) THEN RAISE invalid; END IF;
 SELECT raw_table,result_table,row_count INTO :raw_name,:result_name,:expected_n
   FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_BATCHES WHERE run_id=:requested_run AND batch=:requested_batch;
 IF (raw_name<>'KUMO_SEMANTIC_DEMO.RESULTS.KUMO_'||requested_batch||'_'||requested_run
    OR result_name<>'KUMO_SEMANTIC_DEMO.RESULTS.RETAIL_'||requested_batch||'_'||requested_run
    OR raw_name IS NULL OR result_name IS NULL OR expected_n IS NULL) THEN RAISE invalid; END IF;
 population_name := 'KUMO_SEMANTIC_DEMO.RESULTS.V2_POPULATION_'||requested_run;
 SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_RUNS
   WHERE run_id=:requested_run AND status='TRAINED_NOT_SCORED' AND model_version IS NOT NULL;
 IF (n<>1) THEN RAISE invalid; END IF;
 SELECT model_version,semantic_hash INTO :version,:fingerprint FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_RUNS WHERE run_id=:requested_run;
 SELECT COUNT(*) INTO :n FROM IDENTIFIER(:raw_name);
 IF (n<>expected_n OR n=0) THEN RAISE invalid; END IF;
 SELECT COUNT(*) INTO :n FROM IDENTIFIER(:raw_name)
   WHERE entity IS NULL OR "True_PROB" IS NULL OR "False_PROB" IS NULL OR target_pred IS NULL
     OR NOT "True_PROB" BETWEEN 0 AND 1 OR NOT "False_PROB" BETWEEN 0 AND 1
     OR ABS("True_PROB"+"False_PROB"-1)>0.00001
     OR TRY_TO_BOOLEAN(target_pred::VARCHAR) IS NULL
     OR ("True_PROB">=0.5)<>TRY_TO_BOOLEAN(target_pred::VARCHAR);
 IF (n<>0) THEN RAISE invalid; END IF;
 SELECT COUNT(*)-COUNT(DISTINCT entity) INTO :n FROM IDENTIFIER(:raw_name);
 IF (n<>0) THEN RAISE invalid; END IF;
 SELECT COUNT(*) INTO :n FROM IDENTIFIER(:raw_name) r FULL OUTER JOIN
   (SELECT entity1 FROM IDENTIFIER(:population_name) WHERE batch=:requested_batch) p ON r.entity=p.entity1
   WHERE r.entity IS NULL OR p.entity1 IS NULL;
 IF (n<>0) THEN RAISE invalid; END IF;
 -- The source, not just the final projection, must have no unexpected columns.
 SELECT COUNT(*) INTO :n FROM KUMO_SEMANTIC_DEMO.INFORMATION_SCHEMA.COLUMNS
   WHERE table_schema='RESULTS' AND table_name=SPLIT_PART(:raw_name,'.',3)
     AND column_name NOT IN ('ENTITY','TARGET_PRED','True_PROB','False_PROB');
 IF (n<>0) THEN RAISE invalid; END IF;
 CREATE OR REPLACE TEMP TABLE KUMO_SEMANTIC_DEMO.RESULTS.V2_EXPECTED AS
   SELECT p.entity1,p.timestamp,p.target1,p.baseline_prob,r."True_PROB"::DOUBLE probability,
     :requested_run run_id,:version model_version,:fingerprint semantic_hash
   FROM IDENTIFIER(:population_name) p JOIN IDENTIFIER(:raw_name) r ON r.entity=p.entity1 WHERE p.batch=:requested_batch;
 IF (requested_batch='CURRENT') THEN
   CREATE TABLE IDENTIFIER(:result_name) AS SELECT entity1,timestamp,baseline_prob,probability,run_id,model_version,semantic_hash
     FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_EXPECTED;
   ALTER TABLE KUMO_SEMANTIC_DEMO.RESULTS.V2_EXPECTED DROP COLUMN target1;
 ELSE
   CREATE TABLE IDENTIFIER(:result_name) AS SELECT * FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_EXPECTED;
 END IF;
 SELECT COUNT(*) INTO :n FROM (
   (SELECT * FROM IDENTIFIER(:result_name) MINUS SELECT * FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_EXPECTED)
   UNION ALL (SELECT * FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_EXPECTED MINUS SELECT * FROM IDENTIFIER(:result_name)));
 IF (n<>0) THEN RAISE invalid; END IF;
 SELECT COUNT(*),COUNT(*)-COUNT(DISTINCT entity1) INTO :n,:expected_n FROM IDENTIFIER(:result_name);
 IF (expected_n<>0 OR n=0) THEN RAISE invalid; END IF;
 IF (requested_batch='HOLDOUT') THEN
   CALL KUMO_SEMANTIC_DEMO.RESULTS.V2_EVALUATE(:expected_account,:result_name) INTO :metrics;
 END IF;
 UPDATE KUMO_SEMANTIC_DEMO.RESULTS.V2_BATCHES SET status='VALIDATED',metrics=:metrics
   WHERE run_id=:requested_run AND batch=:requested_batch;
 SELECT COUNT(*) INTO :expected_n FROM KUMO_SEMANTIC_DEMO.RESULTS.V2_BATCHES
   WHERE run_id=:requested_run AND status='VALIDATED';
 IF (expected_n=2) THEN
   UPDATE KUMO_SEMANTIC_DEMO.RESULTS.V2_RUNS SET status='SCORED',completed_at=CURRENT_TIMESTAMP() WHERE run_id=:requested_run;
 END IF;
 RETURN OBJECT_CONSTRUCT_KEEP_NULL('table',result_name,'rows',n,'metrics',metrics,'status','VALIDATED');
END;
$$;
GRANT USAGE ON PROCEDURE V2_FINALIZE(VARCHAR,VARCHAR,VARCHAR) TO ROLE KUMO_DEMO_ML;

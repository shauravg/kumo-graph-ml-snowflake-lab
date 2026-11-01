-- SQL generator revision sql-v2. NOT NumPy-identical; never reload existing demo data.
-- Run serially, as OWNER, only after approving the target account and setup.
USE ROLE KUMO_DEMO_OWNER;
USE SECONDARY ROLES NONE;
USE WAREHOUSE KUMO_DEMO_WH;
USE DATABASE KUMO_SEMANTIC_DEMO;
USE SCHEMA RAW;

EXECUTE IMMEDIATE $$
DECLARE
  wrong_account EXCEPTION (-20001, 'Wrong demo account or role');
  nonempty EXCEPTION (-20002, 'Refusing to load nonempty RAW tables');
  n NUMBER;
BEGIN
  IF (CURRENT_ACCOUNT_NAME() <> '<YOUR_ACCOUNT>' OR CURRENT_ROLE() <> 'KUMO_DEMO_OWNER') THEN
    RAISE wrong_account;
  END IF;
  SELECT SUM(n) INTO :n FROM (
    SELECT COUNT(*) n FROM RAW.CUSTOMERS UNION ALL
    SELECT COUNT(*) FROM RAW.CUSTOMER_IDENTITY UNION ALL
    SELECT COUNT(*) FROM RAW.PRODUCTS UNION ALL
    SELECT COUNT(*) FROM RAW.ORDERS UNION ALL SELECT COUNT(*) FROM RAW.ORDER_ITEMS);
  IF (n <> 0) THEN RAISE nonempty; END IF;
END;
$$;

-- Stable keyed hashes: independent of execution order. Latent fields stay in
-- temporary OWNER-only tables, never in governed views or model inputs.
CREATE TEMP TABLE GEN_CUSTOMERS AS
SELECT customer_id,
  GET(ARRAY_CONSTRUCT('NORTH','SOUTH','EAST','WEST'), MOD(ABS(HASH(42, customer_id, 'region')),4))::VARCHAR region,
  GET(ARRAY_CONSTRUCT('WEB','STORE','REFERRAL'), MOD(ABS(HASH(42, customer_id, 'channel')),3))::VARCHAR acquisition_channel,
  '2024-12-02'::TIMESTAMP_NTZ joined_at,
  MOD(ABS(HASH(42, customer_id, 'eligible')),10000) >= 1000 ml_eligible,
  MOD(ABS(HASH(42, customer_id, 'affinity')),5) affinity,
  0.001 + 0.11 * POWER(MOD(ABS(HASH(42, customer_id, 'rate')),1000000)/1000000.0,4) purchase_rate
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) customer_id FROM TABLE(GENERATOR(ROWCOUNT => 10000)));

CREATE TEMP TABLE GEN_PRODUCTS AS
SELECT product_id,
  GET(ARRAY_CONSTRUCT('GROCERY','BEAUTY','HOME','SPORT','APPAREL'), MOD(product_id-1,5))::VARCHAR category,
  ROUND(5 + 95 * MOD(ABS(HASH(42, product_id, 'price')),1000000)/1000000.0,2)::NUMBER(12,2) list_price
FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) product_id FROM TABLE(GENERATOR(ROWCOUNT => 500)));

CREATE TEMP TABLE GEN_ORDERS AS
WITH days AS (
  SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4())-1, '2025-01-01'::DATE) day
  FROM TABLE(GENERATOR(ROWCOUNT => 546))
), purchases AS (
  SELECT c.customer_id, c.affinity, d.day
  FROM GEN_CUSTOMERS c CROSS JOIN days d
  WHERE MOD(ABS(HASH(42,c.customer_id,d.day,'buy')),1000000)/1000000.0
    < c.purchase_rate * (1 + 0.25 * COS(2 * PI() * DAYOFYEAR(d.day)/365.25))
)
SELECT (DATEDIFF(day,'2025-01-01'::DATE,day)*10000 + customer_id)::NUMBER(38,0) order_id,
  customer_id, affinity,
  DATEADD(second,MOD(ABS(HASH(42,customer_id,day,'time')),86400),day::TIMESTAMP_NTZ) ordered_at,
  IFF(MOD(ABS(HASH(42,customer_id,day,'channel')),2)=0,'WEB','STORE') channel,
  1 + MOD(ABS(HASH(42,customer_id,day,'lines')),4) line_count
FROM purchases;

CREATE TEMP TABLE GEN_ITEMS AS
WITH lines AS (
  SELECT o.*, l.column1 line_number,
    IFF(MOD(ABS(HASH(42,o.order_id,l.column1,'affinity')),10)<8,
      1+o.affinity+5*MOD(ABS(HASH(42,o.order_id,l.column1,'product')),100),
      1+MOD(ABS(HASH(42,o.order_id,l.column1,'product')),500)) product_id,
    1+MOD(ABS(HASH(42,o.order_id,l.column1,'quantity')),3) quantity,
    1-0.1*MOD(ABS(HASH(42,o.order_id,l.column1,'discount')),3) discount
  FROM GEN_ORDERS o CROSS JOIN (VALUES (1),(2),(3),(4)) l
  WHERE l.column1 <= o.line_count
), priced AS (
  SELECT l.*, ROUND(p.list_price*l.discount,2)::NUMBER(12,2) unit_price
  FROM lines l JOIN GEN_PRODUCTS p ON p.product_id=l.product_id
)
SELECT (order_id*4+line_number)::NUMBER(38,0) item_id,order_id,product_id,ordered_at,
  quantity,unit_price,(quantity*unit_price)::NUMBER(12,2) line_total FROM priced;

-- All DDL is outside the DML transaction. Roll back every target on insert failure.
EXECUTE IMMEDIATE $$
DECLARE
  nonempty EXCEPTION (-20002, 'Refusing concurrent or repeated load');
  n NUMBER;
BEGIN
  BEGIN TRANSACTION;
  SELECT SUM(n) INTO :n FROM (
    SELECT COUNT(*) n FROM RAW.CUSTOMERS UNION ALL SELECT COUNT(*) FROM RAW.CUSTOMER_IDENTITY UNION ALL
    SELECT COUNT(*) FROM RAW.PRODUCTS UNION ALL SELECT COUNT(*) FROM RAW.ORDERS UNION ALL
    SELECT COUNT(*) FROM RAW.ORDER_ITEMS);
  IF (n <> 0) THEN RAISE nonempty; END IF;
  INSERT INTO RAW.CUSTOMERS SELECT customer_id,region,acquisition_channel,joined_at,ml_eligible FROM GEN_CUSTOMERS;
  INSERT INTO RAW.CUSTOMER_IDENTITY SELECT customer_id,'Synthetic Shopper '||customer_id,
    'synthetic-'||customer_id||'@example.invalid' FROM GEN_CUSTOMERS;
  INSERT INTO RAW.PRODUCTS SELECT product_id,category,list_price FROM GEN_PRODUCTS;
  INSERT INTO RAW.ORDERS
    SELECT o.order_id,o.customer_id,o.ordered_at,o.channel,SUM(i.line_total)
    FROM GEN_ORDERS o JOIN GEN_ITEMS i ON i.order_id=o.order_id
    GROUP BY o.order_id,o.customer_id,o.ordered_at,o.channel;
  INSERT INTO RAW.ORDER_ITEMS SELECT item_id,order_id,product_id,ordered_at,quantity,unit_price,line_total FROM GEN_ITEMS;
  COMMIT;
EXCEPTION WHEN OTHER THEN
  ROLLBACK;
  RAISE;
END;
$$;
DROP TABLE GEN_ITEMS;
DROP TABLE GEN_ORDERS;
DROP TABLE GEN_PRODUCTS;
DROP TABLE GEN_CUSTOMERS;

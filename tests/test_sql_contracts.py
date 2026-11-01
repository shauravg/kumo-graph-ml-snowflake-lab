"""Local SQL metric execution using SQLite-compatible extracted SELECT logic.

These tests exercise the real grouped/ranked metric CTEs; they do NOT compile
Snowflake procedures. SDK tests are mocks, not evidence of a live GPU run.
"""
import math
from pathlib import Path
import random
import sqlite3
import unittest


def reference_metrics(labels, scores):
    """Independent, small-fixture oracle; never used by the runtime."""
    count = len(labels)
    positives = sum(labels)
    positive_scores = [score for label, score in zip(labels, scores) if label]
    negative_scores = [score for label, score in zip(labels, scores) if not label]
    auc = (sum((positive > negative) + 0.5 * (positive == negative)
               for positive in positive_scores for negative in negative_scores)
           / (len(positive_scores) * len(negative_scores))) if positive_scores and negative_scores else None
    ap = (sum(sum(label for label, score in zip(labels, scores) if score >= threshold)
              / sum(score >= threshold for score in scores)
              for threshold in positive_scores) / positives) if positives else None
    threshold = sorted(scores, reverse=True)[max(1, math.ceil(count / 10)) - 1]
    selected = [label for label, score in zip(labels, scores) if score >= threshold]
    return {"rows": count, "positive_rate": positives / count, "auroc": auc,
            "average_precision": ap,
            "brier": sum((score - label) ** 2 for label, score in zip(labels, scores)) / count,
            "top_decile_lift": (sum(selected) / len(selected)) / (positives / count) if positives else None,
            "top_decile_selected_fraction": len(selected) / count}

ROOT = Path(__file__).resolve().parents[1]


class SQLMetricsTests(unittest.TestCase):
    def sql_metrics(self, labels, scores):
        source = (ROOT / "sql/07_finalize.sql").read_text()
        query = source.split("WITH grouped AS (", 1)[1].split("SELECT ARRAY_AGG", 1)[0]
        query = "WITH grouped AS (" + query
        query = query.replace("KUMO_SEMANTIC_DEMO.RESULTS.V2_SCORES", "scores")
        query += """SELECT row_count,positive_rate,
          (positive_rank_sum-total_positive*(total_positive+1)/2.0)/NULLIF(total_positive*(row_count-total_positive),0),
          average_precision,brier,(top_positive/NULLIF(top_n,0))/NULLIF(positive_rate,0),top_n/row_count
          FROM per_model"""
        with sqlite3.connect(":memory:") as db:
            db.create_function("IFF", 3, lambda condition, yes, no: yes if condition else no)
            db.create_function("CEIL", 1, math.ceil)
            db.create_function("POWER", 2, pow)
            db.execute("CREATE TABLE scores(model TEXT,label REAL,score REAL)")
            db.executemany("INSERT INTO scores VALUES ('kumo',?,?)", zip(labels, scores))
            # Snowflake division is fractional; SQLite requires explicit REAL counts.
            query = query.replace("COUNT(*) samples", "COUNT(*)*1.0 samples")
            row = db.execute(query).fetchone()
        return dict(zip(("rows", "positive_rate", "auroc", "average_precision", "brier",
                         "top_decile_lift", "top_decile_selected_fraction"), row))

    def test_actual_sql_matches_reference_with_ties_and_single_classes(self):
        random.seed(42)
        fixtures = [([0,1,0,1],[0,1,0,1]),([0,1,0,1],[.5]*4),([0,0],[.1,.2]),([1,1],[.2,.8])]
        for _ in range(20):
            fixtures.append(([random.randrange(2) for _ in range(37)],
                             [random.randrange(6)/5 for _ in range(37)]))
        for labels, scores in fixtures:
            expected = reference_metrics(labels, scores)
            actual = self.sql_metrics(labels, scores)
            for key, value in actual.items():
                with self.subTest(key=key, scores=scores):
                    if expected[key] is None:
                        self.assertIsNone(value)
                    else:
                        self.assertAlmostEqual(value, expected[key], places=10)

    def test_actual_population_sql_respects_time_boundaries(self):
        from datetime import datetime, timedelta
        source = (ROOT / "sql/06_prepare.sql").read_text()
        counts = source.split("), counts AS (", 1)[1].split("SELECT entity1,timestamp,split,batch", 1)[0]
        query = "WITH counts AS (" + counts + "SELECT entity1,timestamp,split,batch,IFF(batch='CURRENT',NULL,COALESCE(future_count,0)>0) target1 FROM counts WHERE prior_count>0"
        query = query.replace("KUMO_SEMANTIC_DEMO.GOVERNED.CUSTOMERS", "customers")
        query = query.replace("KUMO_SEMANTIC_DEMO.GOVERNED.ORDERS", "orders")
        query = query.replace("DATEADD(day,", "DATEADD('day',")
        class CountIf:
            def __init__(self): self.count = 0
            def step(self, value): self.count += bool(value)
            def finalize(self): return self.count
        with sqlite3.connect(":memory:") as db:
            db.create_function("IFF",3,lambda condition,yes,no:yes if condition else no)
            db.create_function("DATEADD",3,lambda unit,amount,date:(datetime.fromisoformat(date)+timedelta(days=amount)).isoformat())
            db.create_aggregate("COUNT_IF",1,CountIf)
            db.executescript("""CREATE TABLE customers(customer_id INTEGER,joined_at TEXT);
              CREATE TABLE orders(customer_id INTEGER,ordered_at TEXT);
              CREATE TABLE anchors(anchor TEXT,split INTEGER,batch TEXT);
              INSERT INTO customers VALUES (1,'2025-01-01'),(2,'2025-01-01'),(3,'2025-01-01'),(4,'2026-06-01');
              INSERT INTO anchors VALUES ('2026-05-31T00:00:00',NULL,'HOLDOUT'),('2026-05-31T00:00:00',NULL,'CURRENT');
              INSERT INTO orders VALUES (1,'2026-05-31T00:00:00'),(1,'2026-06-30T00:00:00'),
                (2,'2026-03-02T00:00:00'),(3,'2026-05-31T00:00:00'),(3,'2026-06-30T00:00:01'),
                (4,'2026-05-31T00:00:00');""")
            rows = db.execute(query).fetchall()
        observed = {(row[0], row[3]): row[4] for row in rows}
        self.assertEqual(observed, {(1,'HOLDOUT'):1,(1,'CURRENT'):None,(3,'HOLDOUT'):0,(3,'CURRENT'):None})

    def test_no_python_business_logic_in_runtime(self):
        for name in ("pipeline.py", "adapter.py", "runtime.py"):
            text = (ROOT / "retail_demo" / name).read_text()
            for forbidden in ("import pandas", "import numpy", "to_pandas", "labels_at", "binary_metrics", "yaml.safe_load"):
                self.assertNotIn(forbidden, text, (name, forbidden))

    def test_sql_safety_contracts(self):
        contracts = (ROOT / "sql/05_contracts.sql").read_text()
        prepare = (ROOT / "sql/06_prepare.sql").read_text()
        finalize = (ROOT / "sql/07_finalize.sql").read_text()
        for text in (contracts,prepare,finalize):
            self.assertNotIn("EXECUTE AS OWNER",text)
            self.assertNotIn("LANGUAGE PYTHON",text)
        self.assertIn("sql-v2-yaml-bytes",contracts)
        self.assertIn("FULL OUTER JOIN",finalize)
        self.assertIn("ARRAY_SIZE(e.ref_key)<>1",contracts)
        self.assertIn("entity1::VARCHAR",prepare)
        self.assertIn("9007199254740991",prepare)
        self.assertIn("IF (n=0 OR n>config:max_rows::NUMBER)",prepare)
        self.assertIn("target1 IS NULL",finalize)
        self.assertIn("NOT probability BETWEEN 0 AND 1",finalize)
        self.assertIn("cumulative_n-samples<CEIL(total/10.0)",finalize)

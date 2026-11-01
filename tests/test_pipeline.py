"""Mocks only: SQL/SDK orchestration order. No account or GPU is used."""
import unittest
from contextlib import ExitStack
from datetime import datetime
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
from unittest.mock import patch

import runtime_stubs  # noqa: F401  (registers SDK placeholders before import)
from retail_demo.pipeline import run
from retail_demo.runtime import check_identity

RUN_ID = "RUN_" + "A" * 32
MANIFEST = {"contract_version": "sql-v2", "semantic_hash": "reviewed"}
CONFIG = {"seed": 42, "max_rows": 1000000, "pql": "PREDICT ..."}


def fake_sdk(events):
    """Minimal stand-ins for the Kumo, kumoapi and tracking SDK calls."""

    class Connector:
        def __getitem__(self, name):
            events.append(("source", name))
            return name

    class Tracker:
        def __init__(self, **kwargs):
            pass

        def set_experiment(self, *args):
            pass

        def start_run(self, *args):
            return self

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def log_params(self, *args):
            pass

        def log_artifact(self, path):
            assert Path(path).is_file()

        def log_metrics(self, metrics):
            events.append(("metrics", metrics))

    class Trainer:
        training_table_generation_plan = "saved"

        def __init__(self, *args):
            pass

        def fit(self, *args, **kwargs):
            events.append(("fit",))
            model = SimpleNamespace(name="MODEL", version="EXACT_VERSION")
            return SimpleNamespace(published_model=model)

        @classmethod
        def load_from_connector(cls, connector, location):
            events.append(("reload", location.version))
            return cls()

        def predict(self, seeds, **kwargs):
            assert "SEEDS_" in seeds
            return SimpleNamespace(export=lambda config: events.append(("export", config.table_name)))

    plan = SimpleNamespace(training_job=SimpleNamespace(), optimization=SimpleNamespace(),
                           as_json=lambda: "{}")
    kumo = SimpleNamespace(
        configure=lambda **kwargs: None,
        Trainer=Trainer,
        SnowflakeConnector=SimpleNamespace(from_spcs_env=lambda **kwargs: Connector()),
        ModelRegistryLocation=lambda name, version=None: SimpleNamespace(name=name, version=version),
        ModelOutputConfig=lambda *args, **kwargs: kwargs,
        PredictionOutputConfig=lambda **kwargs: SimpleNamespace(**kwargs),
        TrainingTable=SimpleNamespace(from_source_table=lambda source, *args, **kwargs: source),
        PredictionTable=SimpleNamespace(from_source_table=lambda source, **kwargs: source),
        PredictiveQuery=lambda **kwargs: SimpleNamespace(
            validate=lambda: None, suggest_model_plan=lambda *args, **kwargs: plan),
    )
    graph = SimpleNamespace(snapshot=lambda: SimpleNamespace(id="snapshot"))
    return {
        "kumo": kumo,
        "ExperimentTracking": Tracker,
        "RunMode": SimpleNamespace(FAST="FAST"),
        "TrainingTableSpec": lambda **kwargs: kwargs,
        "PredictionArtifactType": SimpleNamespace(PREDICTIONS="predictions"),
        "WriteMode": SimpleNamespace(OVERWRITE="overwrite"),
        "runtime_preflight": lambda *args: "WH",
        "version": lambda name: "test",
        "read_manifest": lambda *args: MANIFEST,
        "build_graph": lambda *args: graph,
    }


def fake_session(events):
    """Return canned results for each SQL procedure the pipeline calls."""

    def sql(text, params=None):
        events.append(("sql", text, params))
        if "V2_PREPARE" in text:
            result = [({"run_id": RUN_ID, "config": CONFIG, "manifest": MANIFEST,
                        "training_table": "KUMO_SEMANTIC_DEMO.RESULTS.V2_TRAIN_" + RUN_ID},)]
        elif text.startswith("SELECT BATCH"):
            result = [(batch, datetime(2026, month, day),
                       f"KUMO_SEMANTIC_DEMO.RESULTS.V2_SEEDS_{batch}_{RUN_ID}",
                       f"KUMO_SEMANTIC_DEMO.RESULTS.KUMO_{batch}_{RUN_ID}")
                      for batch, month, day in [("HOLDOUT", 5, 31), ("CURRENT", 6, 30)]]
        elif "V2_FINALIZE" in text:
            metrics = {"metrics": [{"model": "kumo", "auroc": .7}]} if params[-1] == "HOLDOUT" else None
            result = [({"status": "VALIDATED", "metrics": metrics},)]
        else:
            result = [(1,)]
        return SimpleNamespace(collect=lambda: result)

    return SimpleNamespace(sql=sql)


class PipelineTests(unittest.TestCase):
    def test_no_execution_without_approval(self):
        with patch("retail_demo.pipeline.runtime_preflight") as preflight:
            with self.assertRaisesRegex(RuntimeError, "requires approval"):
                run(None, "UNUSED")
            preflight.assert_not_called()

    def test_reviewed_hash_and_dataset_required_before_execution(self):
        with patch("retail_demo.pipeline.runtime_preflight") as preflight:
            for reviewed_hash, revision in ((None, "sql-v2"), ("reviewed", None)):
                with self.subTest(hash=reviewed_hash, revision=revision):
                    with self.assertRaisesRegex(ValueError, "required"):
                        run(None, "UNUSED", approved=True,
                            expected_semantic_hash=reviewed_hash, dataset_revision=revision)
            preflight.assert_not_called()

    def test_identity_failure_prevents_warehouse_read(self):
        calls = []

        def sql(text, params=None):
            calls.append(text)

            def collect():
                if "ASSERT_IDENTITY" in text:
                    raise RuntimeError("Wrong account")
                return []

            return SimpleNamespace(collect=collect)

        with self.assertRaises(RuntimeError):
            check_identity(SimpleNamespace(sql=sql), "WRONG")
        # Secondary roles disabled, then the identity check fails; no warehouse read.
        self.assertEqual(len(calls), 2)

    def test_training_reload_scoring_uses_sql_tables(self):
        events = []
        with TemporaryDirectory() as scratch, ExitStack() as stack:
            for name, value in fake_sdk(events).items():
                stack.enter_context(patch(f"retail_demo.pipeline.{name}", value))
            record = run(fake_session(events), "DEMO", approved=True,
                         expected_semantic_hash="reviewed", dataset_revision="legacy-v1",
                         scratch_root=scratch)

        self.assertEqual(record["status"], "SCORED")
        self.assertIn(("reload", "EXACT_VERSION"), events)
        self.assertEqual(len([event for event in events if event[0] == "export"]), 2)
        # Training and both scoring batches read the SQL-prepared tables.
        source_names = [event[1] for event in events if event[0] == "source"]
        self.assertEqual(len(source_names), 3)
        self.assertTrue(source_names[0].startswith("V2_TRAIN_"))


if __name__ == "__main__":
    unittest.main()

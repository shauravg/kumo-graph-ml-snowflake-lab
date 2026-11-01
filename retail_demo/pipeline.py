"""Kumo train, register, reload and score workflow wrapped by SQL procedures.

Execution order:
  1. Guards: explicit approval, reviewed semantic hash and dataset revision.
  2. ``V2_PREPARE`` (SQL): data checks, labels, temporal splits, seed tables.
  3. Kumo: build the graph from the SQL manifest, snapshot and train.
  4. Model Registry: publish, then reload the exact returned version.
  5. Per scoring batch: fresh snapshot, predict from SQL seeds, export.
  6. ``V2_FINALIZE`` (SQL): validate outputs and compute holdout metrics.

Python handles only what the Kumo and Experiment Tracking SDKs require.
"""
import json
from importlib.metadata import version
from pathlib import Path

import kumo.engine as kumo
from kumoapi.jobs import PredictionArtifactType, WriteMode
from kumoapi.model_plan import RunMode
from kumoapi.train import TrainingTableSpec
from snowflake.ml.experiment import ExperimentTracking

from retail_demo.adapter import DATABASE, build_graph, read_manifest, variant
from retail_demo.runtime import runtime_preflight

MODEL_NAME = "RETAIL_REPURCHASE_30D"
EXPERIMENT_NAME = "RETAIL_REPURCHASE_EXPERIMENT"
LOGGED_PACKAGES = ("kumo-engine", "snowflake-ml-python")


def _table_name(fully_qualified):
    """Connectors are schema-scoped, so look tables up by their bare name."""
    return fully_qualified.split(".")[-1]


def _call(session, procedure, *params):
    """Call a RESULTS-schema procedure with bound parameters; decode its VARIANT."""
    placeholders = ", ".join("?" for _ in params)
    result = session.sql(
        f"CALL {DATABASE}.RESULTS.{procedure}({placeholders})", params=list(params)
    ).collect()
    return variant(result[0][0])


def _bounded_plan(query, snapshot, row_spec):
    """One FAST experiment with explicit epoch/step limits and no refits."""
    plan = query.suggest_model_plan(snapshot, run_mode=RunMode.FAST, train_table_spec=row_spec)
    plan.training_job.num_experiments = 1
    plan.training_job.refit_trainval = False
    plan.training_job.refit_full = False
    plan.training_job.disable_explain = True
    plan.optimization.max_epochs = 5
    plan.optimization.max_steps_per_epoch = 100
    return plan


def run(session, expected_account, *, approved=False, expected_semantic_hash=None,
        dataset_revision=None, scratch_root="/tmp/kumo-retail-demo"):
    """Train, register, reload and score; return a run summary.

    Raises before touching Snowflake or the GPU unless the run is explicitly
    approved and pinned to a reviewed semantic hash and dataset revision.
    """
    # 1. Guards: no paid GPU work without approval and reviewed inputs.
    if not approved:
        raise RuntimeError("Paid GPU execution requires approval")
    if not expected_semantic_hash or not dataset_revision:
        raise ValueError("Reviewed sql-v2 semantic hash and dataset revision required")
    warehouse = runtime_preflight(session, expected_account, scratch_root)

    # 2. SQL prepares and validates every input table for this run.
    prepared = _call(session, "V2_PREPARE", expected_account, expected_semantic_hash, dataset_revision)
    run_id, config, manifest = prepared["run_id"], prepared["config"], prepared["manifest"]

    # Run-scoped scratch; exist_ok=False refuses to reuse another run's files.
    run_dir = Path(scratch_root) / run_id
    run_dir.mkdir(parents=True, exist_ok=False)
    scratch = run_dir / "scratch"
    scratch.mkdir()
    kumo.configure(scratch_dir=str(scratch))

    # Governed inputs are read-only; outputs and seed tables live in RESULTS.
    source = kumo.SnowflakeConnector.from_spcs_env(
        warehouse=warehouse, database=DATABASE, schema_name="GOVERNED")
    output = kumo.SnowflakeConnector.from_spcs_env(
        warehouse=warehouse, database=DATABASE, schema_name="RESULTS")

    # 3. Graph, predictive query and training rows, all defined by SQL.
    graph = build_graph(manifest, source)
    query = kumo.PredictiveQuery(graph=graph, query=config["pql"])
    query.validate()
    snapshot = graph.snapshot()
    row_spec = TrainingTableSpec(split_col="SPLIT")
    training = kumo.TrainingTable.from_source_table(
        output[_table_name(prepared["training_table"])], row_spec, pq=query, snapshot=snapshot)
    plan = _bounded_plan(query, snapshot, row_spec)
    trainer = kumo.Trainer(plan)

    tracker = ExperimentTracking(session=session, database_name=DATABASE, schema_name="RESULTS")
    tracker.set_experiment(EXPERIMENT_NAME)
    manifest_path = run_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))

    summaries = {}
    with tracker.start_run(run_id):
        tracker.log_params({
            "contract_version": "sql-v2",
            "semantic_hash": manifest["semantic_hash"],
            "dataset_revision": dataset_revision,
            "config": json.dumps(config),
            "snapshot_id": str(snapshot.id),
            "model_plan": plan.as_json(),
            "packages": json.dumps({name: version(name) for name in LOGGED_PACKAGES}),
        })
        tracker.log_artifact(str(manifest_path))

        # 4. Train, publish to the Model Registry and record the exact version.
        fitted = trainer.fit(training, snapshot=snapshot, export_config=kumo.ModelOutputConfig(
            output, location=kumo.ModelRegistryLocation(MODEL_NAME)))
        published = fitted.published_model
        if published is None:
            raise RuntimeError("Registry did not return model version")
        session.sql(
            f"UPDATE {DATABASE}.RESULTS.V2_RUNS SET model_name=?, model_version=?, "
            "status='TRAINED_NOT_SCORED' WHERE run_id=? AND status='PREPARED'",
            params=[published.name, published.version, run_id],
        ).collect()
        tracker.log_params({"model_name": published.name, "model_version": published.version})

        # Score with the reloaded registry model, not the in-memory trainer.
        restored = kumo.Trainer.load_from_connector(output, location=kumo.ModelRegistryLocation(
            published.name, version=published.version))

        # 5. Score each SQL-prepared batch at its own anchor date.
        batches = session.sql(
            f"SELECT BATCH, ANCHOR, SEED_TABLE, RAW_TABLE FROM {DATABASE}.RESULTS.V2_BATCHES "
            "WHERE RUN_ID=? ORDER BY ANCHOR", params=[run_id]).collect()
        for batch, anchor, seed_table, raw_table in batches:
            # The semantic definition must not change between training and scoring.
            batch_manifest = read_manifest(session, expected_account, anchor.isoformat())
            if batch_manifest["semantic_hash"] != expected_semantic_hash:
                raise RuntimeError("Semantic definition changed during run")

            # Fresh snapshot at the scoring cutoff; the fit snapshot is never reused.
            batch_graph = build_graph(batch_manifest, source)
            batch_query = kumo.PredictiveQuery(graph=batch_graph, query=config["pql"])
            batch_query.validate()
            batch_snapshot = batch_graph.snapshot()
            scoring = kumo.PredictionTable.from_source_table(
                output[_table_name(seed_table)], pq=batch_query, snapshot=batch_snapshot,
                plan=restored.training_table_generation_plan)
            prediction = restored.predict(
                scoring, snapshot=batch_snapshot, binary_classification_threshold=0.5)
            # Output names are run-scoped by SQL, so OVERWRITE cannot hit another run.
            prediction.export(kumo.PredictionOutputConfig(
                connector=output, artifact_type=PredictionArtifactType.PREDICTIONS,
                table_name=_table_name(raw_table), write_mode=WriteMode.OVERWRITE))

            # 6. SQL validates the export and computes holdout metrics.
            summary = _call(session, "V2_FINALIZE", expected_account, run_id, batch)
            summaries[batch] = summary
            if summary["metrics"]:
                tracker.log_metrics({
                    f"holdout_{metric['model']}_{key}": value
                    for metric in summary["metrics"]["metrics"]
                    for key, value in metric.items()
                    if key != "model" and value is not None
                })

    return {"run_id": run_id, "status": "SCORED", "model_name": published.name,
            "model_version": published.version, "outputs": summaries,
            "semantic_hash": expected_semantic_hash}

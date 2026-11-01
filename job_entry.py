"""ML Job entrypoint, run inside the Snowflake GPU container as KUMO_DEMO_ML.

Usage: ``job_entry.py <reviewed_sql_v2_hash> <dataset_revision>``

Logs the runtime environment, runs the pipeline and prints a RUN_RECORD line
that can be read back from the job logs.
"""
import importlib.metadata
import json
import os
import platform
import sys
import traceback

# The job payload is not installed as a package; make it importable first.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from snowflake.snowpark import Session  # noqa: E402

from retail_demo.pipeline import run  # noqa: E402

EXPECTED_ACCOUNT = "<YOUR_ACCOUNT>"


def describe_environment():
    """Capture the runtime facts that matter for reproducing a run."""
    return {
        "python": platform.python_version(),
        "machine": platform.machine(),
        "kumo_engine": importlib.metadata.version("kumo-engine"),
        "token_mounted": os.path.isfile("/snowflake/session/token"),
    }


def main():
    if len(sys.argv) != 3:
        raise ValueError("Arguments: reviewed_sql_v2_hash dataset_revision")
    reviewed_hash, dataset_revision = sys.argv[1], sys.argv[2]

    # The job session authenticates with the container's mounted token.
    session = Session.builder.getOrCreate()
    session.use_warehouse("KUMO_DEMO_WH")
    session.use_database("KUMO_SEMANTIC_DEMO")
    session.use_schema("RESULTS")

    environment = describe_environment()
    print("ENVIRONMENT", json.dumps(environment), flush=True)

    record = run(session, EXPECTED_ACCOUNT, approved=True,
                 expected_semantic_hash=reviewed_hash, dataset_revision=dataset_revision)
    record["environment"] = environment
    print("RUN_RECORD", json.dumps(record, default=str), flush=True)
    return record


if __name__ == "__main__":
    try:
        __return__ = main()  # ML Jobs reads __return__ as the job result
    except Exception:
        # Print the full traceback so it appears in the job logs, then fail.
        traceback.print_exc()
        raise

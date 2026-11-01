"""Submit the Kumo pipeline as a Snowflake ML Job on the dedicated GPU pool.

Usage: python submit_job.py <reviewed_sql_v2_hash> <dataset_revision>

Run locally with a Snowflake connection named "demo". The job itself runs
inside Snowflake as KUMO_DEMO_ML; nothing trains on this machine.
"""
import shutil
import sys
import tempfile
from pathlib import Path

from snowflake.ml.jobs import submit_directory
from snowflake.snowpark import Session

CONNECTION = "demo"
COMPUTE_POOL = "KUMO_DEMO_GPU_POOL"
PAYLOAD_STAGE = "@KUMO_SEMANTIC_DEMO.RESULTS.KUMO_JOB_PAYLOADS"
ROOT = Path(__file__).resolve().parent


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: python submit_job.py <reviewed_sql_v2_hash> <dataset_revision>")

    session = Session.builder.config("connection_name", CONNECTION).config("role", "KUMO_DEMO_ML").create()
    session.sql("USE SECONDARY ROLES NONE").collect()
    session.sql("USE WAREHOUSE KUMO_DEMO_WH").collect()

    # Upload only the runtime code: the entrypoint and the retail_demo package.
    with tempfile.TemporaryDirectory() as payload:
        shutil.copy(ROOT / "job_entry.py", payload)
        shutil.copytree(ROOT / "retail_demo", Path(payload) / "retail_demo",
                        ignore=shutil.ignore_patterns("__pycache__"))
        job = submit_directory(
            payload, COMPUTE_POOL,
            entrypoint="job_entry.py",
            stage_name=PAYLOAD_STAGE,
            args=sys.argv[1:],
            pip_requirements=["kumo-engine[snowflake]==1.0.0", "snowflake-ml-python>=1.19"],
            external_access_integrations=["KUMO_DEMO_PYPI_EAI"],
            database="KUMO_SEMANTIC_DEMO", schema="RESULTS", session=session)

    print("Submitted", job.id)
    # Blocks until the job finishes, then prints the job's own log output.
    print("Status", job.wait())
    print(job.get_logs()[-4000:])


if __name__ == "__main__":
    main()

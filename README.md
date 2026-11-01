# SQL-first governed retail predictions with Kumo Engine

Revision 2 moves generation, semantic authoring, metadata validation, labels, populations, metrics and result processing into Snowflake SQL. Python is limited to the Kumo SDK, experiment SDK logging, and GPU/runtime orchestration. PQL is Kumo's query language, not executable Snowflake SQL.

**Status:** **Live validated 2026-10-26** in the demo account: all SQL procedures compiled and ran; role/masking/eligibility/RAW-denial checks and Snowflake metric fixtures passed; GPU job `JOB_ENTRY_E59C69C5_9T6Z13N1ZS6X` trained, registered and reloaded `RETAIL_REPURCHASE_30D` version `FLUFFY_ANT_1`, scored both batches (run `RUN_6947D838BB864AEC89750C9515ADFAE4`, status SCORED). 11 local tests pass. The SQL generator (03) was validated separately in a disposable database (deterministic, all integrity checks pass); the model run reused the existing `legacy-numpy-v1` dataset. See [evidence](docs/evidence.md).

Open [the editable visual walkthrough](article/workflow.html) for the SQL/Python boundary and execution order.

## SQL owns the workflow

| File | Purpose |
|---|---|
| `sql/01_setup_review.sql` | Existing administrator setup, secure views, roles, masking and resources |
| `sql/03_generate_synthetic.sql` | Optional, deterministic SQL generation on **empty targets only** |
| `sql/04_semantic_view.sql` | Canonical native semantic DDL; no silent replacement |
| `sql/02_semantic_queries.sql` | Explicit semantic grants and descriptive queries |
| `sql/05_contracts.sql` | Config, independent allowlists, caller-rights identity checks, SQL semantic manifest |
| `sql/06_prepare.sql` | Integrity checks, training labels, temporal splits, scoring seed tables and baseline |
| `sql/07_finalize.sql` | Probability/population checks, normalized output, tie-aware metrics and aggregates |
| `sql/08_acceptance.sql` | Role-by-role manual acceptance checks |
| `sql/99_cleanup.sql` | Optional teardown: drops every demo object (irreversible) |
| `tests/sql_acceptance.sql` | Deferred Snowflake-only metric fixtures and error checks |

Run order differs from filename order: **01, optional 03, 04, 02, 05, 06, 07, 08**. Do not execute against the currently selected account without verifying it is the approved demo.

## Python that remains

- `retail_demo/adapter.py`: instantiate Kumo Table/Graph/Edge objects from the SQL-produced manifest.
- `retail_demo/pipeline.py`: invoke SQL procedures; call Kumo fit, registry publication/reload, snapshot and prediction APIs; pass SQL-calculated metrics to Experiment Tracking.
- `retail_demo/runtime.py`: runtime identity bridge, platform/version/token and scratch checks.
- `job_entry.py`: entrypoint for the separately approved Snowflake GPU job.
- `submit_job.py`: submits `job_entry.py` as a Snowflake ML Job on the GPU pool and waits for it (run locally).

No pandas source-table downloads, local seed Parquet generation, Python metric computation or YAML parsing remain in the runtime path. SQL casts graph and seed IDs to VARCHAR (Kumo 1.0.0 rejects float graph keys; verified live) and the training SPLIT column to DOUBLE (decimal is rejected), with an exact-integer bound check on source keys.

Only the SQL-first implementation is retained. Use the SQL procedures directly for acceptance and reporting; `sql/04_semantic_view.sql` is the single local semantic definition.

## Validation

```bash
.venv/bin/python -B -S -m unittest discover -s tests -v
```

The local tests execute extracted metric and population SELECT logic in SQLite with compatibility functions, compare metrics with a small independent standard-library oracle in the tests, and mock the SDK bridge. They do **not** validate Snowflake scripting/DDL, permissions, or GPU compatibility. The local suite needs no third-party packages. Install `requirements-snowflake.txt` only inside the approved GPU runtime.

The SQL generator is revision `sql-v2`, not a bit-for-bit port of NumPy. Reuse the existing dataset as `legacy-numpy-v1` when comparing behavior; never rerun the generator into populated tables. New data requires new metrics.

## Safety and limitations

- Procedures execute as CALLER; the ML role gains no RAW access through OWNER procedures.
- No grants to PUBLIC or future result-table grants.
- Sources must remain unchanged during a run; reads and snapshots are not an atomic multi-table snapshot.
- Failed runs may leave partial run-scoped artifacts. Review them; never mark them validated or overwrite another run.
- The v2 hash is SHA-256 of the exported YAML bytes with a version prefix. It is intentionally incompatible with the old Python canonical-JSON hash and sensitive to export formatting changes.
- A model-registry entry does not provide warehouse-native inference for Kumo. Models and graph snapshots have separate lifecycles.
- No deployment, GPU run, scheduling, public hosting or posting is included in this refactor.

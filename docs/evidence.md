# Article evidence checklist

## SQL-first revision 2 (2026-10-26)

### Live validation (2026-10-26, demo account <YOUR_ACCOUNT>)

- [x] 05/06/07 installed as OWNER. Live fixes: reserved alias `rows`, cursor-record FOR loops replaced by index loops, `EXTENSION/CA` DESCRIBE row allowed (name index only), missing `USE WAREHOUSE`.
- [x] 08 acceptance: RAW 10,000/10,000/121,022/302,267/500; owner sees 0 names/emails, steward 10,000; 0 ineligible rows in governed customers/orders/items; `V2_CHECK_DATA` PASS as ML; reader semantic sales 25,741,600.63; reader denied RAW and GOVERNED (2003).
- [x] Manifest: 4 tables, 3 edges, no identity columns. New hash `75a298af59f4b86bdeb36e224b5c407b918a9587393b3df834ac43af45cfc64b`.
- [x] `tests/sql_acceptance.sql` PASS: perfect/tied metrics, single-class JSON nulls, NaN and empty rejection.
- [x] GPU jobs: `JOB_ENTRY_CA4ECBD3_1GXVN1GYZYUPE` FAILED (float64 graph key rejected); `JOB_ENTRY_64CD54FB_FDOYZKOHFSBD` FAILED (decimal SPLIT rejected); `JOB_ENTRY_E59C69C5_9T6Z13N1ZS6X` DONE in ~5 min. Failed runs `RUN_E93A584B...`, `RUN_DD69D9CA...` remain PREPARED as audit records.
- [x] Run `RUN_6947D838BB864AEC89750C9515ADFAE4` SCORED; model `RETAIL_REPURCHASE_30D` version `FLUFFY_ANT_1` (alias LAST; `CALM_EARWIG_1` remains DEFAULT) registered and reloaded; val AUROC 0.731.
- [x] Both batches VALIDATED: holdout 6,476, current 6,217 unique, no null probabilities (range 0.164-0.870). Outputs contain no identity columns; reader denied on result table.
- [x] Experiment run stored with SQL metrics (inspected via SHOW RUNS).
- [x] Pool suspended (STOPPING, 0 jobs, 0 active nodes); warehouse SUSPENDED.
- [x] SQL generator 03 validated in a disposable database `KUMO_GEN_VALIDATE` (empty RAW tables created LIKE the originals; only the `USE DATABASE` line changed; dropped afterwards). Against the real populated RAW it refused with -20002 and left all rows unchanged (121,022 orders).
  - Load completed in 31s: 10,000 customers/identity rows, 500 products, 126,191 orders, 315,447 items; 8,145 buying customers; 2.50 lines/order; sales 30,431,750.05; orders span 2025-01-01 to 2026-06-30.
  - 0 duplicate/null keys, orphan orders/items, line-math errors, header/line mismatches or orders without items; eligibility 90.48%; all emails `@example.invalid`; temporary GEN_ tables cleaned up.
  - A repeat run on populated targets refused; a rerun after truncation produced identical `HASH_AGG` fingerprints for all five tables (deterministic).
  - Not tested: the masking policy (the generator relies on `01_setup_review.sql` for it), concurrent loads, or the downstream model on this sql-v2 dataset.
- [ ] Credit cost not measured.

| Holdout (v2, tie-aware SQL) | AUROC | Average precision | Brier | Top-decile lift |
|---|---|---|---|---|
| Kumo Engine | 0.705 | 0.632 | 0.273 | 1.70x |
| Recency/frequency baseline | 0.638 | 0.549 | 0.246 | 1.49x |

The baseline's AUROC, Brier and lift equal v1 exactly, so the SQL labels and populations reproduce the original Python ones on the same data. Baseline AP differs from the old 0.582 only because v2 groups tied scores.

The live results below belong to the original NumPy-generated dataset and v1 runtime. They must not be represented as results from the SQL-first implementation. The SQL generator is a different dataset revision. SQL v2 computes average precision by grouped score thresholds; the earlier independent AP query did not group ties, so its displayed AP values are provisional and should be recomputed before publication.


## Historical v1 offline evidence (retired implementation)

- Synthetic generator determinism, PK uniqueness, FK integrity, line/header amount consistency.
- Synthetic identity values use `example.invalid`; no customer identity input source.
- Governed-frame population excludes ineligible customers and all their order events.
- YAML round-trip through tracked authoring tool.
- Adapter rejects unapproved sources/columns, unsupported joins and event-time changes.
- SDK wiring tested with a fake SDK only.
- Temporal gaps, probability validation, exact output populations, tied-score evaluation.
- Execution entrypoints reject calls without explicit approval.

These are local code checks, not proof of effective Snowflake RBAC or model quality.

### Recorded local verification

The original offline suite passed 24 tests, including mocked training, registry reload, batch orchestration, and score/timestamp write-back comparison. Full-size synthetic-data acceptance completed separately:

- RAW: 10,000 customers, 10,000 fictional identity rows, 500 products, 121,022 orders, 302,267 order items.
- Approved in-memory projection: 9,034 customers, 110,040 orders, 274,788 order items, 500 products.
- Training/validation/internal-test examples: 51,297 / 6,948 / 7,058.
- Independent holdout population: 6,476; observed synthetic repurchase rate: 43.13%.
- Full-size generation and data checks: 3.64 seconds locally. This is NOT GPU training time or a Snowflake performance benchmark.

The v1 generator, evaluator, wrappers and their tests have been removed. These figures are retained as historical evidence, not reproducible outputs of the active local suite. The v2 suite retains independent metric and temporal-boundary fixtures, SDK mocks and execution-approval guards. Reporting in v2 uses SQL aggregates; actual PNG rendering was never verified.

## Live acceptance (2026-10-22, demo account)

- [x] Provisioning SQL ran; roles granted to the demo operator only, no PUBLIC grants.
- [x] Identity masking: owner role sees 0/10,000 names and emails; steward sees fictional values.
- [x] ML role (`USE SECONDARY ROLES NONE`) denied on RAW (error 2003); reads GOVERNED only.
- [x] Governed counts match offline projection: 9,034 / 110,040 / 274,788 / 500.
- [x] Semantic view deployed via `SYSTEM$CREATE_SEMANTIC_VIEW_FROM_YAML`; header sales and line sales both reconcile to 25,741,600.63.
- [x] Semantic hash `8d977b1061ac73c7…`; adapter derived 3 edges: ORDERS→CUSTOMERS, ORDER_ITEMS→ORDERS, ORDER_ITEMS→PRODUCTS.
- [x] Runtime: Python 3.12.12, x86_64, NVIDIA A10G (GPU_NV_S), kumo-engine 1.0.0, PyPI-only EAI.
- [x] Graph: 4 node tables, 340,349 nodes, 1,134,158 edges.
- [x] Training: FAST plan, 5 epochs; val AUROC 0.728, val AP 0.773, internal test AUROC 0.722.
- [x] Model `RETAIL_REPURCHASE_30D` version `CALM_EARWIG_1` registered (default) and reloaded for scoring; experiment `RETAIL_REPURCHASE_EXPERIMENT` exists.
- [x] Holdout batch 6,476 rows; current batch 6,217 unique customers, no null probabilities, 0 ineligible customers scored.
- [x] `True_PROB` checked against `False_PROB` and `TARGET_PRED` inside the run.
- [x] Kumo and baseline scored on identical holdout rows (metrics below, recomputed in SQL).
- [x] Outputs contain no identity columns; reader role denied on RESULTS, GOVERNED and RAW until explicitly granted.
- [x] Dedicated GPU pool and warehouse suspended after the run.
- [ ] Experiment run contents (logged params/metrics) not inspected in UI.
- [ ] Measured credit cost not pulled from metering views.
- [ ] Public artifacts scrubbed of account identifiers before publishing.

First job failed in Kumo validation: Snowflake returned `ENTITY1` as int32 and Kumo requires int64 entity keys. Fixed with an explicit cast plus regression test; second job succeeded. End-to-end wall clock about 10 minutes across both jobs.

## Holdout results (synthetic, 2026-05-31 anchor, 30-day window)

| Model | AUROC | Average precision (not tie-aware) | Brier | Top-decile lift |
|---|---|---|---|---|
| Kumo Engine | 0.700 | 0.621 | 0.277 | 1.67x |
| Recency/frequency baseline | 0.638 | 0.582 | 0.246 | 1.49x |

Positive rate 43.1%. Kumo ranks better; baseline is better calibrated. Do not present Kumo probabilities as calibrated without a calibration step.

## Publication claims

Safe now: workflow ran inside Snowflake under a restricted role; graph built from semantic view relationships via custom adapter; registered model and reload; the holdout numbers above, labeled synthetic.

Do not claim: zero infrastructure, zero copying, legal anonymization, a built-in Kumo semantic importer, automatic translation of every semantic construct, measured business ROI, guaranteed model improvement, or deletion of learned information by changing a masking policy.

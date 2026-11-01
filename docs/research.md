# Research and supported scope

Researched October 21, 2026. Updated October 26 for SQL-first revision 2.

Revision 2 uses native semantic DDL and SQL DESCRIBE metadata processing instead of the original Python YAML parser. SQL owns labels, populations, checks, metrics and normalization; Python retains the Kumo and Experiment Tracking SDK calls. Versioned vendor documentation supports supplied source tables, and the direct Snowflake supplied-table path with SQL VARCHAR key projections was verified live on October 26. The original runtime installed and ran Kumo successfully; any pending-runtime language below is preserved historical research, not the status of that original run.

## Confirmed in official documentation

Snowflake's [October 21 launch article](https://www.snowflake.com/en/blog/nvidia-kumo-graph-ml-snowflake/) describes NVIDIA Kumo Engine on Snowflake ML. The [Snowflake quickstart](https://www.snowflake.com/en/developers/guides/getting-started-with-nvidia-kumo-graph-neural-networks-in-snowflake/) demonstrates training and predictions inside Snowflake.

[NVIDIA setup](https://docs.nvidia.com/sdgm/kumo-engine/1.0.0/get-started-with-kumo-engine/installation/snowflake-notebook) specifies GPU Container Runtime 2.9, Python 3.12 and runtime-identity authentication. No Kumo account or API key is required. Compute pools and the SQL query warehouse are separate resources.

[PyPI metadata](https://pypi.org/project/kumo-engine/1.0.0/) exposes Engine 1.0.0 and a Linux x86_64 wheel. Pin: `kumo-engine[snowflake]==1.0.0`. This project's code follows the synchronous API in versioned documentation, not hosted job APIs or different launch-blog signatures. Actual dependency installation and GPU smoke tests remain pending.

[NVIDIA tables](https://docs.nvidia.com/sdgm/kumo-engine/1.0.0/user-code-guide/set-up-a-graph/tables) documents explicit column selection and SQL sources. [Graphs](https://docs.nvidia.com/sdgm/kumo-engine/1.0.0/user-code-guide/set-up-a-graph/graphs) documents alias mappings, FK-to-PK edges, schema validation and materialized snapshots. Schema validation does not prove uniqueness or referential integrity; this demo separately validates rows.

[Predictive queries](https://docs.nvidia.com/sdgm/kumo-engine/1.0.0/user-code-guide/train-a-model/predictive-queries) documents `(start, end]` windows and supplied training rows with ENTITY1, TIMESTAMP, TARGET1 and SPLIT. We supply deterministic labels independently matching PQL to make splits auditable. We do not claim that this particular workflow automatically generates all labels through Kumo.

[Training](https://docs.nvidia.com/sdgm/kumo-engine/1.0.0/user-code-guide/train-a-model/training) documents bounded plans, fit results and retained model bundles. [Registry publication/retrieval](https://docs.nvidia.com/sdgm/kumo-engine/1.0.0/user-code-guide/train-a-model/publish-and-retrieve-models) documents ModelOutputConfig, ModelRegistryLocation and restoration of a fitted Trainer. Registry publication does not itself provide warehouse-native inference. Bundles exclude graph snapshots and source rows, but learned parameters and encoders still require protection.

[Prediction output](https://docs.nvidia.com/sdgm/kumo-engine/1.0.0/user-code-guide/making-predictions) and [Snowflake grants](https://docs.nvidia.com/sdgm/kumo-engine/1.0.0/user-code-guide/connect-your-data-snowflake) document output tables, temporary file formats and authenticated user staging. Do not expand RAW permissions to solve an SDK staging failure.

## Semantic integration

Snowflake's [export function](https://docs.snowflake.com/en/sql-reference/functions/system_read_yaml_from_semantic_view) and [YAML specification](https://docs.snowflake.com/en/user-guide/views-semantic/semantic-view-yaml-spec) expose base objects, primary keys and relationship mappings. This project's adapter maps those constructs to Kumo Table/Edge objects. A vendor-provided native importer was not verified.

V1 intentionally supports direct columns, single-column primary keys, and equality relationships referencing those primary keys. Composite keys, ASOF/range relations, self-relations, arbitrary SQL sources, filter labels, private expressions and cross-table expressions are rejected. Aggregate metrics are not automatically translated into features. Event-time selections are separately reviewed, not guessed from arbitrary dates.

## Governance boundaries

Snowflake [semantic governance guidance](https://docs.snowflake.com/en/user-guide/views-semantic/best-practices-dev) explains owner-rights semantic queries, underlying policy enforcement, and unmasked metadata sample values. Our semantic definition contains no sensitive sample values.

The ML connector reads GOVERNED views directly. Its access is enforced by grants and explicit view projections, not magically inherited from semantic metadata. An independent allowlist prevents metadata edits from widening the input contract. Declared keys are not trusted without data checks.

The snapshot index contains materialized data in the Snowflake compute environment. New masking rules do not erase existing scratch or learned model parameters. Policy changes require reviewing retained snapshots, caches, model versions, and output tables; rebuild/retrain or remove them as appropriate. Customer surrogate keys would remain potentially linkable in a real deployment. No privacy-law certification is claimed.

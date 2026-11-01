"""Bridge from the SQL-validated semantic manifest to Kumo graph objects.

All semantic validation (allowlists, keys, relationships, event times) happens in
the ``V2_MANIFEST`` SQL procedure. This module only reads that manifest and
instantiates the corresponding Kumo SDK objects; it contains no business logic.
"""
import json

import kumo.engine as kumo
from kumoapi.graph import Edge
from kumoapi.typing import Stype

DATABASE = "KUMO_SEMANTIC_DEMO"


def variant(value):
    """Decode a Snowflake VARIANT result.

    Some Snowpark client versions return VARIANT values as JSON text, others as
    already-parsed Python objects.
    """
    return json.loads(value) if isinstance(value, str) else value


def read_manifest(session, expected_account, cutoff):
    """Return the SQL-produced semantic manifest for the given time cutoff.

    Parameters are bound, never interpolated, so caller input cannot alter SQL.
    """
    result = session.sql(
        f"CALL {DATABASE}.RESULTS.V2_MANIFEST(?, ?::TIMESTAMP_NTZ)",
        params=[expected_account, cutoff],
    ).collect()
    return variant(result[0][0])


def build_graph(manifest, connector):
    """Build and validate a Kumo graph from a ``sql-v2`` manifest.

    Each manifest table supplies a governed SQL projection, primary key, event
    time column and categorical columns. Each relationship becomes one Kumo edge
    from a foreign key to the referenced table.
    """
    if manifest.get("contract_version") != "sql-v2":
        raise ValueError("Expected SQL-validated v2 manifest")

    # Foreign keys must be typed as IDs so Kumo treats them as graph links.
    foreign_keys = {}
    for edge in manifest["relationships"]:
        foreign_keys.setdefault(edge["source"], []).append(edge["foreign_key"])

    tables = {}
    for table in manifest["tables"]:
        built = kumo.Table.from_sql(
            connector,
            table["source_sql"],
            primary_key=table["primary_key"],
            time_column=table["time_column"],
        )
        for column in table["categorical_columns"]:
            built = built.with_column(column, stype=Stype.categorical)
        for column in foreign_keys.get(table["alias"], []):
            built = built.with_column(column, stype=Stype.ID)
        tables[table["alias"]] = built

    edges = [
        Edge(src_table=edge["source"], fkey=edge["foreign_key"], dst_table=edge["destination"])
        for edge in manifest["relationships"]
    ]
    graph = kumo.Graph(tables=tables, edges=edges)
    graph.validate()
    return graph

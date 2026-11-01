"""Mocks only: the graph bridge must use exactly what the SQL manifest returns."""
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import runtime_stubs  # noqa: F401  (registers SDK placeholders before import)
from retail_demo.adapter import build_graph


class SDKContractTests(unittest.TestCase):
    def test_sdk_uses_sql_manifest(self):
        calls = []

        class Table:
            @classmethod
            def from_sql(cls, connector, query, **kwargs):
                calls.append((query, kwargs))
                return cls()

            def with_column(self, *args, **kwargs):
                return self

        class Graph:
            def __init__(self, **kwargs):
                self.__dict__.update(kwargs)

            def validate(self):
                self.validated = True

        fake_kumo = SimpleNamespace(Table=Table, Graph=Graph)
        stype = SimpleNamespace(ID="ID", categorical="categorical")
        manifest = {
            "contract_version": "sql-v2",
            "tables": [{"alias": "A", "primary_key": "ID", "time_column": None,
                        "source_sql": "SELECT ID FROM APPROVED", "categorical_columns": []}],
            "relationships": [{"source": "A", "foreign_key": "FK", "destination": "B"}],
        }
        with patch("retail_demo.adapter.kumo", fake_kumo), \
                patch("retail_demo.adapter.Edge", lambda **kwargs: kwargs), \
                patch("retail_demo.adapter.Stype", stype):
            graph = build_graph(manifest, object())
            self.assertTrue(graph.validated)
            self.assertEqual(graph.edges, [{"src_table": "A", "fkey": "FK", "dst_table": "B"}])
            self.assertEqual(calls[0][0], "SELECT ID FROM APPROVED")
            with self.assertRaises(ValueError):
                build_graph({"contract_version": "old"}, object())


if __name__ == "__main__":
    unittest.main()

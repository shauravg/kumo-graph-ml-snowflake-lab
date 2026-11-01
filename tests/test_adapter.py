"""Mocks only: SQL VARIANT decoding and bound manifest parameters."""
import unittest
from types import SimpleNamespace

import runtime_stubs  # noqa: F401  (registers SDK placeholders before import)
from retail_demo.adapter import read_manifest, variant


class AdapterTests(unittest.TestCase):
    def test_variant_transport(self):
        self.assertEqual(variant('{"contract_version":"sql-v2"}'), {"contract_version": "sql-v2"})
        data = {"tables": []}
        self.assertIs(variant(data), data)

    def test_manifest_parameters_are_bound(self):
        calls = []

        def sql(text, params):
            calls.append((text, params))
            return SimpleNamespace(collect=lambda: [('{"contract_version":"sql-v2"}',)])

        result = read_manifest(SimpleNamespace(sql=sql), "ACCOUNT", "2026-04-01")
        self.assertEqual(result["contract_version"], "sql-v2")
        self.assertEqual(calls[0][1], ["ACCOUNT", "2026-04-01"])
        self.assertIn("?::TIMESTAMP_NTZ", calls[0][0])


if __name__ == "__main__":
    unittest.main()

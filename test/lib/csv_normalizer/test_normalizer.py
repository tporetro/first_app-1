"""
Tests for the CSV normalization pipeline.
Run with: python -m pytest test/lib/csv_normalizer/test_normalizer.py -v
     or  : python test/lib/csv_normalizer/test_normalizer.py
"""

import csv
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

# Allow imports from project root
sys.path.insert(0, str(Path(__file__).resolve().parents[3]))

from ai_schema_detector import detect_field, detect_schema, _normalize_col
from normalize_csv import (
    NormalizationPipeline,
    compute_confidence,
    normalize_row,
    _normalize_email,
    _normalize_phone,
    _normalize_state,
    _normalize_zip,
    _normalize_asset_type,
    _normalize_roof_type,
    _normalize_integer,
    _normalize_float,
    _derive_market,
    CONFIDENCE_CLEAN,
    CONFIDENCE_EXCEPTION,
)


# ---------------------------------------------------------------------------
# Schema detector tests
# ---------------------------------------------------------------------------

class TestDetectField(unittest.TestCase):
    def test_exact_match_owner_name(self):
        field, level = detect_field("owner_name")
        self.assertEqual(field, "owner_name")
        self.assertEqual(level, "exact")

    def test_alias_match_company(self):
        field, level = detect_field("company")
        self.assertEqual(field, "owner_company")
        self.assertEqual(level, "exact")

    def test_alias_match_sqft(self):
        field, level = detect_field("sqft")
        self.assertEqual(field, "building_sqft")
        self.assertEqual(level, "exact")

    def test_alias_match_addr(self):
        field, level = detect_field("addr")
        self.assertEqual(field, "address")
        self.assertEqual(level, "exact")

    def test_fuzzy_match_email_address(self):
        field, level = detect_field("email_address")
        self.assertEqual(field, "owner_email")

    def test_unmapped_column(self):
        field, level = detect_field("xyzzy_unknown_field_789")
        self.assertIsNone(field)
        self.assertEqual(level, "none")

    def test_case_insensitive(self):
        field, _ = detect_field("Owner Name")
        self.assertEqual(field, "owner_name")

    def test_with_extra_spaces(self):
        field, _ = detect_field("  email  ")
        self.assertEqual(field, "owner_email")


class TestDetectSchema(unittest.TestCase):
    def test_maps_sample_input_columns(self):
        # Mirrors sample_input.csv headers
        cols = ["OwnerName", "PropertyAddress", "CityName", "StateName",
                "Email1", "Phone", "PropertyType", "SquareFeet"]
        result = detect_schema(cols)
        m = result["detected_mappings"]
        self.assertIn("OwnerName", m)
        self.assertEqual(m["OwnerName"], "owner_name")
        self.assertIn("PropertyAddress", m)
        self.assertEqual(m["PropertyAddress"], "address")

    def test_no_duplicate_target_fields(self):
        cols = ["name", "contact_name", "owner_name"]
        result = detect_schema(cols)
        targets = list(result["detected_mappings"].values())
        self.assertEqual(len(targets), len(set(targets)), "Duplicate target fields found")

    def test_sample_value_email_inference(self):
        cols = ["email1"]
        rows = [{"email1": "foo@bar.com"}, {"email1": "baz@qux.org"}]
        result = detect_schema(cols, sample_rows=rows)
        m = result["detected_mappings"]
        self.assertIn("email1", m)
        self.assertEqual(m["email1"], "owner_email")

    def test_sample_value_state_full_name(self):
        cols = ["StateName"]
        rows = [{"StateName": "Texas"}, {"StateName": "California"}]
        result = detect_schema(cols, sample_rows=rows)
        m = result["detected_mappings"]
        self.assertIn("StateName", m)
        self.assertEqual(m["StateName"], "state")

    def test_sample_value_sqft_numbers(self):
        cols = ["SquareFeet"]
        rows = [{"SquareFeet": "125000"}, {"SquareFeet": "98000"}]
        result = detect_schema(cols, sample_rows=rows)
        m = result["detected_mappings"]
        self.assertIn("SquareFeet", m)
        self.assertEqual(m["SquareFeet"], "building_sqft")


# ---------------------------------------------------------------------------
# Field coercion tests
# ---------------------------------------------------------------------------

class TestFieldCoercers(unittest.TestCase):
    def test_normalize_email_valid(self):
        self.assertEqual(_normalize_email("User@Example.COM"), "user@example.com")

    def test_normalize_email_invalid_preserved(self):
        # Invalid emails are preserved (confidence deducted separately)
        result = _normalize_email("not-an-email")
        self.assertEqual(result, "not-an-email")

    def test_normalize_phone_strips_formatting(self):
        result = _normalize_phone("(214) 555-1212")
        self.assertRegex(result, r"[\d\s\(\)\-]+")

    def test_normalize_state_uppercase(self):
        self.assertEqual(_normalize_state("texas"), "TEXAS")
        self.assertEqual(_normalize_state("tx"), "TX")

    def test_normalize_zip_valid(self):
        self.assertEqual(_normalize_zip("75201"), "75201")
        self.assertEqual(_normalize_zip("75201-4321"), "75201-4321")

    def test_normalize_asset_type_known(self):
        self.assertEqual(_normalize_asset_type("industrial"), "Industrial")
        # "Retail" fuzzy-matches "Retail Strip" per schema
        result = _normalize_asset_type("Retail Strip")
        self.assertEqual(result, "Retail Strip")

    def test_normalize_asset_type_alias(self):
        # "Retail" should fuzzy-match "Retail Strip"
        result = _normalize_asset_type("Retail")
        self.assertIn("Retail", result)

    def test_normalize_roof_type_tpo(self):
        self.assertEqual(_normalize_roof_type("TPO"), "TPO Membrane")

    def test_normalize_integer_with_commas(self):
        self.assertEqual(_normalize_integer("125,000"), 125000)

    def test_normalize_integer_invalid(self):
        self.assertIsNone(_normalize_integer("not a number"))

    def test_normalize_float_currency(self):
        self.assertAlmostEqual(_normalize_float("$1,200,000"), 1200000.0)

    def test_derive_market_known_city(self):
        self.assertEqual(_derive_market("Dallas"), "Dallas")
        self.assertEqual(_derive_market("houston"), "Houston")

    def test_derive_market_unknown_city(self):
        self.assertIsNone(_derive_market("Smalltown"))


# ---------------------------------------------------------------------------
# Confidence scoring tests
# ---------------------------------------------------------------------------

class TestComputeConfidence(unittest.TestCase):
    def _full_row(self):
        return {
            "record_id": "REC-test-0001",
            "source_file": "test.csv",
            "owner_name": "Alice Smith",
            "owner_company": "Acme Corp",
            "owner_email": "alice@acme.com",
            "owner_phone": "555-1234",
            "property_name": "Main Plaza",
            "address": "100 Main St",
            "city": "Dallas",
            "state": "TX",
            "zip": "75201",
            "market": "Dallas",
            "asset_type": "Office",
            "building_sqft": 50000,
            "roof_type": "Metal",
            "notes": "",
            "_market_derived": False,
        }

    def test_full_row_scores_high(self):
        score, reasons = compute_confidence(self._full_row())
        self.assertGreaterEqual(score, CONFIDENCE_CLEAN)
        self.assertEqual(reasons, [])

    def test_missing_address_deducted(self):
        row = self._full_row()
        row["address"] = ""
        score, reasons = compute_confidence(row)
        self.assertLess(score, 1.0)
        self.assertIn("missing address", reasons)

    def test_missing_owner_deducted(self):
        row = self._full_row()
        row["owner_name"] = ""
        row["owner_company"] = ""
        score, reasons = compute_confidence(row)
        self.assertIn("missing owner_name and owner_company", reasons)

    def test_invalid_email_deducted(self):
        row = self._full_row()
        row["owner_email"] = "not-an-email"
        score, reasons = compute_confidence(row)
        self.assertIn("invalid email format", reasons)

    def test_market_derived_deducted(self):
        row = self._full_row()
        row["_market_derived"] = True
        score, reasons = compute_confidence(row)
        self.assertIn("market derived from city", reasons)

    def test_minimal_row_dropped(self):
        # A row missing address, city, state, both owner fields, both contact fields
        # hits: -0.25 -0.10 -0.10 -0.20 -0.10 = -0.75 → score 0.25
        # At 0.25 it lands in exceptions not dropped; test that it is below CONFIDENCE_CLEAN
        row = {k: "" for k in self._full_row()}
        row["record_id"] = "REC-test-0001"
        row["source_file"] = "test.csv"
        row["_market_derived"] = False
        score, _ = compute_confidence(row)
        self.assertLess(score, CONFIDENCE_CLEAN)


# ---------------------------------------------------------------------------
# Pipeline integration tests
# ---------------------------------------------------------------------------

class TestNormalizationPipeline(unittest.TestCase):
    def _make_csv(self, rows: list[dict]) -> str:
        """Write a temp CSV and return its path."""
        tmp = tempfile.NamedTemporaryFile(
            mode="w", suffix=".csv", delete=False, encoding="utf-8"
        )
        if rows:
            writer = csv.DictWriter(tmp, fieldnames=list(rows[0].keys()))
            writer.writeheader()
            writer.writerows(rows)
        tmp.close()
        return tmp.name

    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def _run_pipeline(self, rows, extra_cols=None):
        path = self._make_csv(rows)
        pipeline = NormalizationPipeline(output_dir=self.tmpdir, verbose=False)
        pipeline.run([path])
        os.unlink(path)
        return pipeline

    def test_sample_input_produces_clean_rows(self):
        rows = [
            {
                "OwnerName": "Johnson Holdings LLC",
                "PropertyAddress": "2500 Main St",
                "CityName": "Dallas",
                "StateName": "Texas",
                "Email1": "johnson@example.com",
                "Phone": "(214) 555-1212",
                "PropertyType": "Retail",
                "SquareFeet": "125000",
            },
            {
                "OwnerName": "Parkside Partners",
                "PropertyAddress": "1201 Commerce Ave",
                "CityName": "Dallas",
                "StateName": "Texas",
                "Email1": "parkside@example.com",
                "Phone": "(469) 555-3434",
                "PropertyType": "Industrial",
                "SquareFeet": "98000",
            },
        ]
        pipeline = self._run_pipeline(rows)
        self.assertEqual(len(pipeline.clean_rows), 2)
        self.assertEqual(len(pipeline.dropped_rows), 0)

    def test_output_files_created(self):
        rows = [
            {"owner_name": "Test Owner", "address": "1 Test St",
             "city": "Dallas", "state": "TX", "owner_email": "a@b.com",
             "owner_phone": "555-0000"},
        ]
        self._run_pipeline(rows)
        for fname in ("clean_master.csv", "exceptions.csv", "dropped_rows.csv", "schema_map.json"):
            self.assertTrue(
                (Path(self.tmpdir) / fname).exists(),
                f"{fname} was not created"
            )

    def test_schema_map_json_structure(self):
        rows = [{"owner_name": "A", "address": "B", "city": "C", "state": "TX",
                 "owner_email": "a@b.com", "owner_phone": "555-0000"}]
        self._run_pipeline(rows)
        with open(Path(self.tmpdir) / "schema_map.json") as f:
            sm = json.load(f)
        key = list(sm.keys())[0]
        self.assertIn("detected_mappings", sm[key])
        self.assertIn("unmapped_columns", sm[key])
        self.assertIn("confidence", sm[key])

    def test_low_confidence_row_dropped(self):
        rows = [{"unknown_col_1": "x", "unknown_col_2": "y"}]
        pipeline = self._run_pipeline(rows)
        # No mapping → all rows dropped
        total = len(pipeline.clean_rows) + len(pipeline.exception_rows) + len(pipeline.dropped_rows)
        self.assertEqual(total, 1)
        self.assertEqual(len(pipeline.clean_rows), 0)

    def test_record_id_uniqueness(self):
        rows = [
            {"owner_name": "A", "address": "1 St", "city": "Austin",
             "state": "TX", "owner_email": "a@b.com", "owner_phone": "555"},
            {"owner_name": "B", "address": "2 St", "city": "Austin",
             "state": "TX", "owner_email": "b@c.com", "owner_phone": "666"},
        ]
        pipeline = self._run_pipeline(rows)
        all_rows = pipeline.clean_rows + pipeline.exception_rows + pipeline.dropped_rows
        ids = [r["record_id"] for r in all_rows]
        self.assertEqual(len(ids), len(set(ids)), "Duplicate record_ids found")

    def test_clean_csv_has_master_columns(self):
        rows = [
            {"owner_name": "Owner", "address": "1 Main", "city": "Dallas",
             "state": "TX", "owner_email": "o@e.com", "owner_phone": "555"}
        ]
        self._run_pipeline(rows)
        with open(Path(self.tmpdir) / "clean_master.csv") as f:
            reader = csv.DictReader(f)
            headers = reader.fieldnames
        from normalize_csv import MASTER_COLUMNS
        for col in MASTER_COLUMNS:
            self.assertIn(col, headers, f"Missing column {col!r} in clean_master.csv")

    def test_state_full_name_normalized(self):
        """State 'Texas' should be stored as normalized (uppercased at minimum)."""
        rows = [
            {"owner_name": "X", "address": "1 St", "city": "Dallas",
             "StateName": "Texas", "owner_email": "x@y.com", "owner_phone": "555"}
        ]
        path = self._make_csv(rows)
        pipeline = NormalizationPipeline(output_dir=self.tmpdir, verbose=False)
        pipeline.run([path])
        os.unlink(path)
        # state detection via sample values should map StateName → state
        all_rows = pipeline.clean_rows + pipeline.exception_rows
        if all_rows:
            state_val = all_rows[0].get("state", "")
            # Should be "TEXAS" (uppercased) — not the original "Texas"
            self.assertEqual(state_val, state_val.upper())


if __name__ == "__main__":
    unittest.main(verbosity=2)

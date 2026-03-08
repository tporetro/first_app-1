#!/usr/bin/env python3
"""
normalize_csv.py — CSV Normalization Pipeline
==============================================
Reads arbitrary CSV input files, maps columns to the master schema,
normalizes values, and writes:

  clean_master.csv   — rows with confidence >= 0.6
  exceptions.csv     — rows with 0.2 <= confidence < 0.6
  dropped_rows.csv   — rows with confidence < 0.2 or un-parseable
  schema_map.json    — detected column mappings per source file

Usage:
  python normalize_csv.py --input <file_or_dir> [--output <dir>] [--strict] [--verbose]

See DATA_SCHEMA.md and SYSTEM_CONTEXT.md for full documentation.
"""

import argparse
import csv
import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional

from ai_schema_detector import detect_schema, build_schema_map

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CONFIDENCE_CLEAN = 0.6
CONFIDENCE_EXCEPTION = 0.2

VALID_ASSET_TYPES = {
    "multifamily", "retail strip", "office", "flex industrial",
    "industrial", "hospitality", "mixed use", "land", "other",
}

VALID_ROOF_TYPES = {
    "tpo membrane", "built-up", "metal", "shingle", "epdm",
    "modified bitumen", "other",
}

VALID_STATES = {
    "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA",
    "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD",
    "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ",
    "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA", "RI", "SC",
    "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
    "DC",
}

# City → market derived mapping (common metros)
CITY_TO_MARKET = {
    "houston": "Houston", "katy": "Houston", "pearland": "Houston",
    "humble": "Houston", "beaumont": "Houston", "galveston": "Houston",
    "austin": "Austin", "round rock": "Austin", "cedar park": "Austin",
    "dallas": "Dallas", "fort worth": "Dallas", "irving": "Dallas",
    "plano": "Dallas", "arlington": "Dallas", "frisco": "Dallas",
    "san antonio": "San Antonio", "new braunfels": "San Antonio",
    "el paso": "El Paso", "lubbock": "Lubbock", "amarillo": "Amarillo",
    "new york": "New York", "brooklyn": "New York", "queens": "New York",
    "los angeles": "Los Angeles", "long beach": "Los Angeles",
    "chicago": "Chicago", "phoenix": "Phoenix", "philadelphia": "Philadelphia",
    "san antonio": "San Antonio", "san diego": "San Diego",
    "jacksonville": "Jacksonville", "san francisco": "San Francisco",
    "columbus": "Columbus", "charlotte": "Charlotte", "indianapolis": "Indianapolis",
    "denver": "Denver", "seattle": "Seattle", "nashville": "Nashville",
    "oklahoma city": "Oklahoma City", "las vegas": "Las Vegas",
    "miami": "Miami", "atlanta": "Atlanta", "minneapolis": "Minneapolis",
}

# ---------------------------------------------------------------------------
# Value normalizers
# ---------------------------------------------------------------------------

def _strip(value: str) -> str:
    return value.strip() if value else ""


def _normalize_string(value: str) -> str:
    return _strip(value)


def _normalize_integer(value: str) -> Optional[int]:
    cleaned = re.sub(r"[,\s$]", "", value.strip())
    try:
        return int(float(cleaned))
    except (ValueError, TypeError):
        return None


def _normalize_float(value: str) -> Optional[float]:
    cleaned = re.sub(r"[,\s$]", "", value.strip())
    try:
        return float(cleaned)
    except (ValueError, TypeError):
        return None


def _normalize_email(value: str) -> str:
    v = value.strip().lower()
    if re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", v):
        return v
    return v  # preserve; validation noted separately


def _normalize_phone(value: str) -> str:
    return re.sub(r"[^\d\+\-\(\)\s\.]", "", value.strip())


def _normalize_state(value: str) -> str:
    return value.strip().upper()


def _normalize_zip(value: str) -> str:
    z = re.sub(r"[^\d\-]", "", value.strip())
    # Accept 5-digit or ZIP+4
    if re.match(r"^\d{5}(-\d{4})?$", z):
        return z
    return z


def _normalize_asset_type(value: str) -> str:
    v = value.strip()
    if not v:
        return v
    lower = v.lower()
    if lower in VALID_ASSET_TYPES:
        return _title_asset(lower)
    # Fuzzy: check substring
    for valid in VALID_ASSET_TYPES:
        if lower in valid or valid in lower:
            return _title_asset(valid)
    return v


def _title_asset(lower: str) -> str:
    return " ".join(w.capitalize() for w in lower.split())


def _normalize_roof_type(value: str) -> str:
    v = value.strip()
    if not v:
        return v
    lower = v.lower()
    if lower in VALID_ROOF_TYPES:
        return _title_roof(lower)
    for valid in VALID_ROOF_TYPES:
        if lower in valid or valid in lower:
            return _title_roof(valid)
    return v


def _title_roof(lower: str) -> str:
    special = {"tpo": "TPO", "epdm": "EPDM"}
    return " ".join(special.get(w, w.capitalize()) for w in lower.split())


def _derive_market(city: str) -> Optional[str]:
    return CITY_TO_MARKET.get(city.strip().lower())


def _is_valid_email(value: str) -> bool:
    return bool(re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", value.strip()))


# ---------------------------------------------------------------------------
# Confidence scoring
# ---------------------------------------------------------------------------

def compute_confidence(row: dict) -> tuple[float, list[str]]:
    """
    Compute confidence score for a normalized row.
    Returns (score, [reason, ...]).
    """
    score = 1.0
    reasons: list[str] = []

    if not row.get("address"):
        score -= 0.25
        reasons.append("missing address")

    if not row.get("city"):
        score -= 0.10
        reasons.append("missing city")

    if not row.get("state"):
        score -= 0.10
        reasons.append("missing state")

    if not row.get("owner_name") and not row.get("owner_company"):
        score -= 0.20
        reasons.append("missing owner_name and owner_company")

    if not row.get("owner_email") and not row.get("owner_phone"):
        score -= 0.10
        reasons.append("missing owner_email and owner_phone")

    if row.get("owner_email") and not _is_valid_email(row["owner_email"]):
        score -= 0.05
        reasons.append("invalid email format")

    asset = row.get("asset_type", "").strip().lower()
    if row.get("asset_type") and asset not in VALID_ASSET_TYPES:
        score -= 0.05
        reasons.append(f"unknown asset_type: {row['asset_type']!r}")

    roof = row.get("roof_type", "").strip().lower()
    if row.get("roof_type") and roof not in VALID_ROOF_TYPES:
        score -= 0.05
        reasons.append(f"unknown roof_type: {row['roof_type']!r}")

    if row.get("_market_derived"):
        score -= 0.05
        reasons.append("market derived from city")

    return round(max(0.0, score), 4), reasons


# ---------------------------------------------------------------------------
# Row normalization
# ---------------------------------------------------------------------------

def normalize_row(
    raw_row: dict,
    mapping: dict[str, str],
    source_file: str,
    row_index: int,
) -> dict:
    """
    Apply the column mapping and normalize all field values.
    Returns the normalized master row (always includes all master fields).
    """
    # Build mapped source dict: master_field → raw_value
    mapped: dict[str, str] = {}
    for src_col, master_field in mapping.items():
        if src_col in raw_row and raw_row[src_col]:
            mapped[master_field] = raw_row[src_col]

    out: dict = {
        "record_id": f"REC-{Path(source_file).stem}-{row_index:04d}",
        "source_file": source_file,
        "owner_name": _normalize_string(mapped.get("owner_name", "")),
        "owner_company": _normalize_string(mapped.get("owner_company", "")),
        "owner_email": _normalize_email(mapped.get("owner_email", "")),
        "owner_phone": _normalize_phone(mapped.get("owner_phone", "")),
        "property_name": _normalize_string(mapped.get("property_name", "")),
        "address": _normalize_string(mapped.get("address", "")),
        "city": _normalize_string(mapped.get("city", "")),
        "state": _normalize_state(mapped.get("state", "")),
        "zip": _normalize_zip(mapped.get("zip", "")),
        "market": _normalize_string(mapped.get("market", "")),
        "asset_type": _normalize_asset_type(mapped.get("asset_type", "")),
        "building_sqft": _normalize_integer(mapped.get("building_sqft", "")),
        "roof_type": _normalize_roof_type(mapped.get("roof_type", "")),
        "notes": _normalize_string(mapped.get("notes", "")),
        "_market_derived": False,
    }

    # Derive market from city if not provided
    if not out["market"] and out["city"]:
        derived = _derive_market(out["city"])
        if derived:
            out["market"] = derived
            out["_market_derived"] = True

    return out


# ---------------------------------------------------------------------------
# Master schema field order for CSV output
# ---------------------------------------------------------------------------

MASTER_COLUMNS = [
    "record_id", "source_file",
    "owner_name", "owner_company", "owner_email", "owner_phone",
    "property_name", "address", "city", "state", "zip", "market",
    "asset_type", "building_sqft", "roof_type", "notes",
    "confidence_score",
]

EXCEPTION_COLUMNS = MASTER_COLUMNS + ["exception_reason"]
DROPPED_COLUMNS = MASTER_COLUMNS + ["drop_reason"]


# ---------------------------------------------------------------------------
# Pipeline
# ---------------------------------------------------------------------------

class NormalizationPipeline:
    def __init__(self, output_dir: str, strict: bool = False, verbose: bool = False):
        self.output_dir = Path(output_dir)
        self.strict = strict
        self.verbose = verbose

        self.clean_rows: list[dict] = []
        self.exception_rows: list[dict] = []
        self.dropped_rows: list[dict] = []
        self.schema_map: dict[str, dict] = {}

        self.stats: dict[str, dict] = {}

    def log(self, level: str, msg: str):
        if level == "INFO" and not self.verbose:
            return
        prefix = {"INFO": "  ", "WARN": "⚠ ", "ERROR": "✗ "}
        print(f"{prefix.get(level, '')}[{level}] {msg}", file=sys.stderr)

    def process_file(self, filepath: str):
        filename = os.path.basename(filepath)
        self.log("INFO", f"Processing {filename}")

        try:
            with open(filepath, newline="", encoding="utf-8-sig") as f:
                reader = csv.DictReader(f)
                source_columns = reader.fieldnames or []
                rows = list(reader)
        except Exception as e:
            self.log("ERROR", f"Cannot read {filename}: {e}")
            return

        # Detect schema using headers + up to 5 sample rows for value inference
        schema_info = detect_schema(source_columns, sample_rows=rows[:5])
        self.schema_map[filename] = schema_info
        mapping = schema_info["detected_mappings"]

        if not mapping:
            self.log("WARN", f"{filename}: no columns mapped — all rows will be dropped")

        unmapped = schema_info["unmapped_columns"]
        if unmapped:
            self.log("INFO", f"{filename}: unmapped columns: {unmapped}")

        file_stats = {"total": 0, "clean": 0, "exceptions": 0, "dropped": 0}

        for i, raw_row in enumerate(rows, start=1):
            file_stats["total"] += 1

            try:
                norm = normalize_row(raw_row, mapping, filename, i)
            except Exception as e:
                self.log("ERROR", f"{filename} row {i}: normalization failed — {e}")
                drop = {col: "" for col in DROPPED_COLUMNS}
                drop["record_id"] = f"REC-{Path(filename).stem}-{i:04d}"
                drop["source_file"] = filename
                drop["drop_reason"] = f"normalization error: {e}"
                drop["confidence_score"] = 0.0
                self.dropped_rows.append(drop)
                file_stats["dropped"] += 1
                continue

            score, reasons = compute_confidence(norm)
            norm["confidence_score"] = score
            reason_str = "; ".join(reasons)

            # Clean internal flag before output
            norm.pop("_market_derived", None)

            if score >= CONFIDENCE_CLEAN:
                self.clean_rows.append(norm)
                file_stats["clean"] += 1
            elif score >= CONFIDENCE_EXCEPTION:
                norm["exception_reason"] = reason_str
                self.exception_rows.append(norm)
                file_stats["exceptions"] += 1
                self.log("WARN", f"{filename} row {i} → exceptions (score={score}): {reason_str}")
            else:
                norm["drop_reason"] = reason_str or "insufficient data"
                self.dropped_rows.append(norm)
                file_stats["dropped"] += 1
                self.log("WARN", f"{filename} row {i} → dropped (score={score}): {reason_str}")

        self.stats[filename] = file_stats
        self.log("INFO", f"{filename}: {file_stats}")

    def run(self, inputs: list[str]):
        self.output_dir.mkdir(parents=True, exist_ok=True)

        for path in inputs:
            p = Path(path)
            if p.is_dir():
                for csv_file in sorted(p.glob("*.csv")):
                    self.process_file(str(csv_file))
            elif p.is_file():
                self.process_file(str(p))
            else:
                self.log("ERROR", f"Input not found: {path}")

        self._write_outputs()
        self._print_summary()

        error_count = sum(s["dropped"] for s in self.stats.values())
        if self.strict and error_count > 0:
            sys.exit(1)

    def _write_csv(self, rows: list[dict], columns: list[str], filename: str):
        path = self.output_dir / filename
        with open(path, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=columns, extrasaction="ignore")
            writer.writeheader()
            for row in rows:
                # Fill missing keys with empty string
                out = {col: (row.get(col) if row.get(col) is not None else "") for col in columns}
                writer.writerow(out)
        return path

    def _write_outputs(self):
        self._write_csv(self.clean_rows, MASTER_COLUMNS, "clean_master.csv")
        self._write_csv(self.exception_rows, EXCEPTION_COLUMNS, "exceptions.csv")
        self._write_csv(self.dropped_rows, DROPPED_COLUMNS, "dropped_rows.csv")

        schema_map_path = self.output_dir / "schema_map.json"
        schema_map_path.write_text(build_schema_map(self.schema_map), encoding="utf-8")

    def _print_summary(self):
        total_rows = sum(s["total"] for s in self.stats.values())
        total_clean = sum(s["clean"] for s in self.stats.values())
        total_exc = sum(s["exceptions"] for s in self.stats.values())
        total_drop = sum(s["dropped"] for s in self.stats.values())
        total_files = len(self.stats)

        print()
        print("=" * 60)
        print(" CSV Normalization Summary")
        print("=" * 60)
        print(f"  Files processed : {total_files}")
        print(f"  Total rows      : {total_rows}")
        print(f"  Clean           : {total_clean:>6}  → clean_master.csv")
        print(f"  Exceptions      : {total_exc:>6}  → exceptions.csv")
        print(f"  Dropped         : {total_drop:>6}  → dropped_rows.csv")
        print(f"  Schema map      : schema_map.json")
        print(f"  Output dir      : {self.output_dir}")
        print("=" * 60)
        print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Normalize arbitrary CSVs to the master schema (DATA_SCHEMA.md).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python normalize_csv.py --input neo4j/import/csv --output output/
  python normalize_csv.py --input raw/properties.csv --output output/ --verbose
  python normalize_csv.py --input raw/ --output clean/ --strict
        """,
    )
    parser.add_argument(
        "--input", "-i", nargs="+", required=True,
        help="Input CSV file(s) or directory",
    )
    parser.add_argument(
        "--output", "-o", default="output",
        help="Output directory (default: ./output)",
    )
    parser.add_argument(
        "--strict", action="store_true",
        help="Exit 1 if any rows are dropped",
    )
    parser.add_argument(
        "--verbose", action="store_true",
        help="Print INFO-level messages",
    )

    args = parser.parse_args()

    pipeline = NormalizationPipeline(
        output_dir=args.output,
        strict=args.strict,
        verbose=args.verbose,
    )
    pipeline.run(args.input)


if __name__ == "__main__":
    main()

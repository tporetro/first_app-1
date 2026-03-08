# CSV Normalization Pipeline — System Context

## Purpose

The CSV normalization engine transforms raw source data (from CRM exports,
spreadsheet dumps, insurance APIs, or manual entry) into clean, schema-valid
CSV files ready for direct Neo4j `LOAD CSV` import.

## Pipeline Architecture

```
[Raw Source CSVs]
       │
       ▼
┌─────────────────────────────────────────┐
│  1. INGEST                              │
│  Read source CSV with Ruby stdlib CSV   │
│  Auto-detect delimiter, encoding        │
│  Strip BOM, normalize line endings      │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│  2. FIELD MAPPING                       │
│  Map source column names → canonical    │
│  column names defined in DATA_SCHEMA.md │
│  Uses configurable alias map            │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│  3. COERCE & NORMALIZE per field        │
│  • string  → strip whitespace, nil→""  │
│  • integer → parse, clamp to range      │
│  • float   → parse, strip $/, symbols  │
│  • date    → parse multiple formats     │
│               → ISO 8601 output         │
│  • boolean → "true"/"yes"/"1" → "true" │
│              "false"/"no"/"0" → "false" │
│  • enum    → case-insensitive match     │
│              warn on unknown value      │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│  4. VALIDATE                            │
│  • Required fields present              │
│  • ID pattern match                     │
│  • Referential: FK IDs exist in related │
│    node file (optional strict mode)     │
│  • Business rules (e.g. ownership ≤ 100)│
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│  5. EMIT                                │
│  Write normalized CSV to output dir     │
│  Same filename as target schema file    │
│  Columns in canonical schema order      │
└──────────────────┬──────────────────────┘
                   │
                   ▼
┌─────────────────────────────────────────┐
│  6. REPORT                              │
│  Print summary: rows processed,         │
│  warnings, errors per file              │
│  Exit 0 if no errors; exit 1 otherwise  │
└─────────────────────────────────────────┘
```

## File Processing Order

Node files must be normalized before relationship files so FK validation can
resolve references:

```
Node files (any order):
  persons.csv
  companies.csv
  markets.csv
  storm_events.csv
  proof_projects.csv
  properties.csv
  users.csv

Relationship files (after nodes):
  rel_owns.csv
  rel_manages.csv
  rel_located_in.csv
  rel_affected_by.csv
  rel_connected_to.csv
  rel_similar_to.csv
  rel_proof_near.csv
  rel_user_activity.csv
  rel_person_company.csv
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Ruby stdlib only | No gem dependencies — runs in any Rails app context |
| Warn, don't drop | Rows with non-fatal errors are written with a warning; fatal errors drop the row and log it |
| Idempotent output | Running the normalizer twice produces identical output |
| Schema-driven | All rules come from `SchemaDefinitions` — no hardcoded field logic |
| FK validation optional | Enable with `--strict` flag; off by default for partial imports |

## Error Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| ERROR | Missing required field, bad ID pattern | Row is skipped; reported |
| WARN | Unknown enum value, out-of-range number, unresolvable FK | Row written with original value; reported |
| INFO | Extra columns in source, trimmed whitespace | Logged at verbose level |

## CLI Usage

```bash
# Normalize all CSVs from source dir to output dir
python normalize_csv.py --input neo4j/import/csv --output output/

# Normalize a single file
python normalize_csv.py --input sample_input.csv --output output/

# Strict mode: exit 1 if any rows are dropped
python normalize_csv.py --input raw/ --output clean/ --strict

# Verbose: print INFO-level messages too
python normalize_csv.py --input raw/ --output clean/ --verbose
```

## Implementation Files

| File | Purpose |
|------|---------|
| `normalize_csv.py` | Main pipeline: ingest → detect → normalize → emit |
| `ai_schema_detector.py` | Column name fuzzy matching + sample-value inference |
| `sample_input.csv` | Example messy CSV for testing |
| `DATA_SCHEMA.md` | Master schema definition (source of truth) |
| `SYSTEM_CONTEXT.md` | This document |
| `test/lib/csv_normalizer/test_normalizer.py` | Unit + integration tests |

## Integration with Neo4j Import

After normalization, copy output CSVs to the Neo4j import directory and run:

```bash
cd neo4j/scripts
NEO4J_PASSWORD=yourpassword ./setup.sh
```

The import scripts (`import_nodes.cypher`, `import_relationships.cypher`) read
directly from `file:///import/csv/*.csv`, so the normalized files must be placed
in the Neo4j import directory (see `setup.sh` step 1).

## Source Data Assumptions

- Source files may have additional columns not in the schema (ignored with INFO)
- Source files may use alternate column headers (use alias map to remap)
- Dates may arrive in MM/DD/YYYY, YYYY-MM-DD, or M/D/YYYY formats
- Numbers may include commas (1,200,000) or currency symbols ($380,000)
- Booleans may be "TRUE"/"FALSE", "Yes"/"No", "1"/"0", or "true"/"false"
- String fields may have leading/trailing whitespace

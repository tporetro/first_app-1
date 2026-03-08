# CSV Normalization Engine — Data Schema

## Master Output Schema

All incoming CSV files are normalized into the following flat master schema.
This is the canonical target for `clean_master.csv`.

| Field | Type | Required | Constraints | Notes |
|-------|------|----------|-------------|-------|
| record_id | string | ✓ | Auto-generated `REC-{source_file}-{row}` | Unique row identifier |
| source_file | string | ✓ | Filename of origin CSV | Provenance tracking |
| owner_name | string | | Non-empty after strip | Primary contact name |
| owner_company | string | | | Organization name |
| owner_email | string | | Valid email format | |
| owner_phone | string | | Digits, dashes, parens, spaces | |
| property_name | string | | | Building/property name |
| address | string | | | Street address |
| city | string | | | |
| state | string | | 2-letter US state code, uppercase | |
| zip | string | | 5-digit or ZIP+4 | |
| market | string | | Derived from city if not provided | Metro/market area |
| asset_type | string | | Enum (see below) | |
| building_sqft | integer | | ≥ 0 | |
| roof_type | string | | Enum (see below) | |
| notes | string | | | Combined from any notes/comments fields |
| confidence_score | float | ✓ | 0.0–1.0 | Computed per row |

### Enum Values

**asset_type** (case-insensitive match):
`Multifamily`, `Retail Strip`, `Office`, `Flex Industrial`, `Industrial`,
`Hospitality`, `Mixed Use`, `Land`, `Other`

**roof_type** (case-insensitive match):
`TPO Membrane`, `Built-Up`, `Metal`, `Shingle`, `EPDM`,
`Modified Bitumen`, `Other`

---

## Confidence Score Rules

The `confidence_score` is computed per row from 0.0 to 1.0:

| Condition | Deduction |
|-----------|-----------|
| Missing address | −0.25 |
| Missing city | −0.10 |
| Missing state | −0.10 |
| Missing owner_name AND owner_company | −0.20 |
| Missing owner_email AND owner_phone | −0.10 |
| Invalid email format | −0.05 |
| Unknown asset_type value | −0.05 |
| Unknown roof_type value | −0.05 |
| market derived (not provided) | −0.05 |

**Routing rules:**
- `confidence_score >= 0.6` → `clean_master.csv`
- `0.2 <= confidence_score < 0.6` → `exceptions.csv`
- `confidence_score < 0.2` → `dropped_rows.csv`

---

## Output Files

| File | Description |
|------|-------------|
| `clean_master.csv` | Normalized rows with confidence ≥ 0.6 |
| `exceptions.csv` | Rows with 0.2 ≤ confidence < 0.6; include `exception_reason` column |
| `dropped_rows.csv` | Rows with confidence < 0.2 or un-parseable; include `drop_reason` |
| `schema_map.json` | Detected column mappings per source file |

---

## Schema Map Format (`schema_map.json`)

```json
{
  "source_file.csv": {
    "detected_mappings": {
      "Owner Name":      "owner_name",
      "Property":        "property_name",
      "Sq Ft":           "building_sqft",
      "Addr":            "address"
    },
    "unmapped_columns": ["Internal Code", "Last Updated"],
    "confidence":       "high"
  }
}
```

Mapping confidence levels: `exact`, `alias`, `fuzzy`, `none`

---

## Known Column Aliases

The schema detector uses these aliases when source column names do not
exactly match the target field names:

| Target Field | Recognized Aliases |
|---|---|
| owner_name | name, contact, contact_name, person, owner, full_name, first_last |
| owner_company | company, organization, org, firm, employer, company_name |
| owner_email | email, e_mail, contact_email, email_address |
| owner_phone | phone, tel, telephone, mobile, cell, phone_number |
| property_name | property, building, building_name, prop_name, site |
| address | addr, street, street_address, location |
| city | municipality, town |
| state | st, province |
| zip | zip_code, postal_code, postal, zipcode |
| market | metro, metro_area, market_area, region |
| asset_type | type, property_type, prop_type, class, building_type |
| building_sqft | sqft, sq_ft, square_feet, size, area, gla |
| roof_type | roof, roofing, roof_material, roof_system |
| notes | note, comment, comments, description, remarks, memo |

---

## Neo4j Node/Relationship Schemas

The master schema maps into the following Neo4j node types for graph import.
See the Neo4j import pipeline in `neo4j/import/` for full field lists.

| Master Field | Neo4j Node | Neo4j Property |
|---|---|---|
| owner_name | Person | name |
| owner_company | Company | name |
| owner_email | Person | email |
| owner_phone | Person | phone |
| property_name | Property | name |
| address + city + state + zip | Property | address, city, state, zip |
| market | Market | name |
| asset_type | Property | asset_type |
| building_sqft | Property | building_sqft |
| roof_type | Property | roof_type |

#!/usr/bin/env bash
# ============================================================
# Neo4j Opportunity Intelligence System — Full Setup Script
# Runs all Cypher files in correct dependency order against
# a running Neo4j instance via cypher-shell.
#
# Prerequisites:
#   - Neo4j 5.x running locally or via Docker
#   - cypher-shell installed and on PATH
#   - CSV files copied to Neo4j import directory (see below)
#
# Usage:
#   chmod +x setup.sh
#   NEO4J_PASSWORD=yourpassword ./setup.sh
#
# Environment variables (all optional — defaults shown):
#   NEO4J_HOST     = localhost
#   NEO4J_PORT     = 7687
#   NEO4J_USER     = neo4j
#   NEO4J_PASSWORD = neo4j
#   NEO4J_DB       = neo4j
# ============================================================

set -euo pipefail

HOST="${NEO4J_HOST:-localhost}"
PORT="${NEO4J_PORT:-7687}"
USER="${NEO4J_USER:-neo4j}"
PASS="${NEO4J_PASSWORD:-neo4j}"
DB="${NEO4J_DB:-neo4j}"

BOLT="bolt://${HOST}:${PORT}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

run_cypher() {
  local label="$1"
  local file="$2"
  echo -e "  ${GREEN}▶${NC} ${label}"
  cypher-shell \
    -a "$BOLT" \
    -u "$USER" \
    -p "$PASS" \
    -d "$DB" \
    --file "$file" \
    --format plain 2>&1 | tail -5
}

echo ""
echo "============================================================"
echo " Neo4j Opportunity Intelligence System — Setup"
echo " Target: ${BOLT} / db: ${DB}"
echo "============================================================"

# --- Step 1: Copy CSVs to Neo4j import directory ---
echo ""
echo "[1/5] Locating Neo4j import directory..."
NEO4J_IMPORT_DIR=""
for candidate in \
  "/var/lib/neo4j/import" \
  "/usr/local/var/neo4j/import" \
  "$HOME/.neo4j/import" \
  "/data/import"; do
  if [ -d "$candidate" ]; then
    NEO4J_IMPORT_DIR="$candidate"
    break
  fi
done

if [ -z "$NEO4J_IMPORT_DIR" ]; then
  echo -e "  ${RED}WARN${NC}: Could not find Neo4j import directory automatically."
  echo "  Please manually copy files from ${ROOT_DIR}/import/csv/ to your Neo4j import dir."
  echo "  Then set NEO4J_IMPORT_DIR and re-run, or skip to step 2."
else
  echo "  Found: ${NEO4J_IMPORT_DIR}"
  mkdir -p "${NEO4J_IMPORT_DIR}/import/csv"
  cp -r "${ROOT_DIR}/import/csv/"*.csv "${NEO4J_IMPORT_DIR}/import/csv/"
  echo "  CSVs copied to ${NEO4J_IMPORT_DIR}/import/csv/"
fi

# --- Step 2: Schema ---
echo ""
echo "[2/5] Applying schema (constraints + indexes)..."
run_cypher "Constraints" "${ROOT_DIR}/schema/constraints.cypher"
run_cypher "Indexes"     "${ROOT_DIR}/schema/indexes.cypher"

# --- Step 3: Import nodes ---
echo ""
echo "[3/5] Importing nodes..."
run_cypher "Nodes" "${ROOT_DIR}/import/import_nodes.cypher"

# --- Step 4: Import relationships ---
echo ""
echo "[4/5] Importing relationships..."
run_cypher "Relationships" "${ROOT_DIR}/import/import_relationships.cypher"

# --- Step 5: Score all properties ---
echo ""
echo "[5/5] Running opportunity scoring engine..."
run_cypher "Scoring Engine" "${ROOT_DIR}/scoring/scoring_engine.cypher"

echo ""
echo "============================================================"
echo " Setup complete."
echo " Run queries from:"
echo "   ${ROOT_DIR}/queries/intelligence_queries.cypher"
echo "   ${ROOT_DIR}/queries/dashboard_queries.cypher"
echo "============================================================"
echo ""

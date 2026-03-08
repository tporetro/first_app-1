#!/usr/bin/env bash
# ============================================================
# Neo4j Opportunity Intelligence System — Re-Score Properties
# Runs only the scoring engine to refresh opportunity_score
# values without re-importing all data.
#
# Usage:
#   chmod +x rescore.sh
#   NEO4J_PASSWORD=yourpassword ./rescore.sh
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

echo ""
echo "============================================================"
echo " Opportunity Intelligence — Re-Scoring Properties"
echo " Target: ${BOLT} / db: ${DB}"
echo "============================================================"
echo ""

cypher-shell \
  -a "$BOLT" \
  -u "$USER" \
  -p "$PASS" \
  -d "$DB" \
  --file "${ROOT_DIR}/scoring/scoring_engine.cypher" \
  --format verbose

echo ""
echo "Scoring complete. Properties updated with fresh opportunity_score."
echo ""

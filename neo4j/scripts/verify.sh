#!/usr/bin/env bash
# ============================================================
# Neo4j Opportunity Intelligence System — Data Verification
# Prints node counts, relationship counts, and top 5 scored
# properties to confirm the import completed correctly.
# ============================================================

set -euo pipefail

HOST="${NEO4J_HOST:-localhost}"
PORT="${NEO4J_PORT:-7687}"
USER="${NEO4J_USER:-neo4j}"
PASS="${NEO4J_PASSWORD:-neo4j}"
DB="${NEO4J_DB:-neo4j}"

BOLT="bolt://${HOST}:${PORT}"

q() {
  cypher-shell -a "$BOLT" -u "$USER" -p "$PASS" -d "$DB" \
    --format plain "$@"
}

echo ""
echo "============================================================"
echo " Neo4j Opportunity Intelligence — Verification Report"
echo "============================================================"
echo ""
echo "--- Node Counts ---"
q --cypher "
MATCH (n)
RETURN LABELS(n)[0] AS label, COUNT(n) AS count
ORDER BY count DESC;"

echo ""
echo "--- Relationship Counts ---"
q --cypher "
MATCH ()-[r]->()
RETURN TYPE(r) AS type, COUNT(r) AS count
ORDER BY count DESC;"

echo ""
echo "--- Top 5 Opportunity Properties ---"
q --cypher "
MATCH (pr:Property)
RETURN pr.name AS property,
       pr.city AS city,
       pr.opportunity_score AS score,
       pr.estimated_value AS value
ORDER BY pr.opportunity_score DESC
LIMIT 5;"

echo ""
echo "--- Score Component Sanity Check ---"
q --cypher "
MATCH (pr:Property)
RETURN
  MIN(pr.opportunity_score) AS min_score,
  MAX(pr.opportunity_score) AS max_score,
  AVG(pr.opportunity_score) AS avg_score,
  COUNT(pr)                 AS total_properties;"

echo ""

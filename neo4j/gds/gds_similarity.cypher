// ============================================================
// GDS Node Similarity — Jaccard Similarity
// "Show me more like this."
//
// Finds nodes that share the same graph neighbors.
// Creates SIMILAR_TO relationships with similarity_score.
//
// Property–Property: shared Market and StormEvent neighbors
// Person–Person:     shared Property neighbors (similar portfolios)
// ============================================================
// Prereq: run gds_projection.cypher first.
// ============================================================

// ── Stream: explore Property similarity pairs before writing ───
// Properties are similar if they share LOCATED_IN → Market targets.
// High similarity = same market, same exposure profile.
CALL gds.nodeSimilarity.stream('opportunityGraph', {
  similarityCutoff: 0.3,
  topK:             5
})
YIELD node1, node2, similarity
WITH gds.util.asNode(node1) AS a,
     gds.util.asNode(node2) AS b,
     similarity
WHERE labels(a)[0] = 'Property'
  AND labels(b)[0] = 'Property'
OPTIONAL MATCH (a)-[:LOCATED_IN]->(m:Market)
RETURN
  a.name                                AS source_property,
  b.name                                AS similar_property,
  round(similarity, 3)                  AS similarity_score,
  COALESCE(m.name, '—')                 AS market,
  COALESCE(a.asset_type, '—')           AS asset_type,
  a.opportunity_score                   AS source_score,
  b.opportunity_score                   AS similar_score
ORDER BY similarity DESC
LIMIT 20;


// ── Stream: explore Person (owner) similarity pairs ────────────
// Owners are similar if they own properties in the same markets.
CALL gds.nodeSimilarity.stream('opportunityGraph', {
  similarityCutoff: 0.2,
  topK:             5
})
YIELD node1, node2, similarity
WITH gds.util.asNode(node1) AS a,
     gds.util.asNode(node2) AS b,
     similarity
WHERE labels(a)[0] = 'Person'
  AND labels(b)[0] = 'Person'
RETURN
  a.name                                AS source_owner,
  a.role                                AS source_role,
  b.name                                AS similar_owner,
  b.role                                AS similar_role,
  round(similarity, 3)                  AS similarity_score
ORDER BY similarity DESC
LIMIT 20;


// ── Write: create SIMILAR_TO relationships ─────────────────────
// Idempotent: MERGE prevents duplicate relationships.
// Stores similarity_score on the relationship.
// After this runs, SIMILAR_TO edges are available in the live graph
// and can be projected in future GDS runs.
CALL gds.nodeSimilarity.stream('opportunityGraph', {
  similarityCutoff: 0.3,
  topK:             5
})
YIELD node1, node2, similarity
WITH gds.util.asNode(node1) AS a,
     gds.util.asNode(node2) AS b,
     similarity
WHERE labels(a)[0] = 'Property'
  AND labels(b)[0] = 'Property'
  AND id(a) < id(b)             // avoid duplicate reverse relationships
MERGE (a)-[r:SIMILAR_TO]-(b)
SET r.similarity_score = round(similarity, 4),
    r.computed_at      = datetime()
RETURN COUNT(r) AS similar_to_relationships_written;

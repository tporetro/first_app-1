// ============================================================
// GDS Centrality Algorithms
// 1. Betweenness Centrality → connector_score
// 2. PageRank               → influence_score
// ============================================================
// Prereq: run gds_projection.cypher first.
// These are STREAM queries — use gds_writeback.cypher to persist.
// ============================================================

// ── 1. Betweenness Centrality — "Who connects clusters?" ──────
//
// Finds bridge nodes that sit on the most shortest paths.
// High connector_score = broker, community figure, deal-enabler.
// Operates on Person nodes across CONNECTED_TO relationships.
CALL gds.betweenness.stream('opportunityGraph')
YIELD nodeId, score
WITH gds.util.asNode(nodeId) AS n, score
WHERE labels(n)[0] IN ['Person', 'Property']
  AND score > 0
RETURN
  labels(n)[0]                      AS type,
  n.name                            AS name,
  n.role                            AS role,
  n.email                           AS email,
  n.trust_score                     AS trust_score,
  round(score, 2)                   AS connector_score,
  round(COALESCE(n.influence_score, 0), 5) AS influence_score
ORDER BY score DESC
LIMIT 25;


// ── 2. PageRank — "Who has network influence?" ─────────────────
//
// Importance flows through the graph — nodes linked to by important
// nodes score higher.  Useful for ranking owners, connectors, proof nodes.
// Operates across all projected relationship types.
CALL gds.pageRank.stream('opportunityGraph', {
  dampingFactor:  0.85,
  maxIterations:  20
})
YIELD nodeId, score
WITH gds.util.asNode(nodeId) AS n, score
WHERE any(l IN labels(n) WHERE l IN ['Person', 'Property', 'ProofProject'])
RETURN
  labels(n)[0]                      AS type,
  n.name                            AS name,
  COALESCE(n.role, n.asset_type)    AS subtype,
  n.opportunity_score               AS opportunity_score,
  round(score, 5)                   AS influence_score,
  round(COALESCE(n.connector_score, 0), 2) AS connector_score
ORDER BY score DESC
LIMIT 30;

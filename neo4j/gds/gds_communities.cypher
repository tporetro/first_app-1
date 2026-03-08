// ============================================================
// GDS Community Detection — Louvain Algorithm
// Detects hidden clusters in the opportunity graph.
// Writes: Person.community_id · Property.community_id
// ============================================================
// Prereq: run gds_projection.cypher first.
// ============================================================

// ── Stream: explore communities before writing ─────────────────
CALL gds.louvain.stream('opportunityGraph')
YIELD nodeId, communityId, intermediateCommunityIds
WITH communityId,
     collect(gds.util.asNode(nodeId)) AS members
WITH communityId,
     SIZE(members)                                                AS node_count,
     SIZE([n IN members WHERE labels(n)[0] = 'Person'])          AS people_count,
     SIZE([n IN members WHERE labels(n)[0] = 'Property'])        AS property_count,
     SIZE([n IN members WHERE labels(n)[0] = 'ProofProject'])    AS proof_count,
     SIZE([n IN members WHERE labels(n)[0] = 'Market'])          AS market_count,
     [n IN members | n.name][..6]                                AS sample_names,
     // Dominant market in community
     [n IN members WHERE labels(n)[0] = 'Market' | n.name][0]   AS dominant_market,
     // Dominant asset type
     [n IN members WHERE n.asset_type IS NOT NULL | n.asset_type][0] AS dominant_asset_type,
     // Average opportunity score for properties in community
     [n IN members WHERE n.opportunity_score IS NOT NULL | n.opportunity_score] AS opp_scores
WHERE node_count >= 2
WITH communityId, node_count, people_count, property_count, proof_count,
     market_count, sample_names, dominant_market, dominant_asset_type,
     CASE SIZE(opp_scores) WHEN 0 THEN null
          ELSE reduce(sum = 0.0, s IN opp_scores | sum + s) / SIZE(opp_scores)
     END AS avg_opportunity_score
RETURN
  communityId                               AS community_id,
  node_count,
  people_count,
  property_count,
  proof_count,
  market_count,
  sample_names,
  dominant_market,
  dominant_asset_type,
  round(COALESCE(avg_opportunity_score, 0), 1) AS avg_opportunity_score
ORDER BY node_count DESC, avg_opportunity_score DESC
LIMIT 20;


// ── Opportunity Cluster Query ──────────────────────────────────
// Combines community_id with market + opportunity score data.
// Returns communities with the strongest opportunity density.
// Run after gds_writeback.cypher has written community_id to nodes.
MATCH (pr:Property)
WHERE pr.community_id IS NOT NULL AND pr.opportunity_score IS NOT NULL
OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
WITH pr.community_id                     AS community_id,
     COALESCE(m.name, 'Unknown')         AS market,
     COUNT(pr)                           AS property_count,
     AVG(pr.opportunity_score)           AS avg_opportunity_score,
     SUM(pr.estimated_value)             AS total_estimated_value
RETURN
  community_id,
  market,
  property_count,
  round(avg_opportunity_score, 1)        AS avg_opportunity_score,
  total_estimated_value
ORDER BY avg_opportunity_score DESC, property_count DESC
LIMIT 15;

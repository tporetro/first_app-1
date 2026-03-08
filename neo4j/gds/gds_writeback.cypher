// ============================================================
// GDS Write-back — Persist Algorithm Results to Node Properties
// ============================================================
// Run after gds_projection.cypher to write GDS scores back to
// Neo4j so dashboards, scoring, and dossier generation can use them.
//
// Properties written:
//   Person:       connector_score · influence_score · community_id
//   Property:     community_id · similarity_score · gravity_score (future)
//   ProofProject: influence_score
// ============================================================
// Prereq: run gds_projection.cypher first.
// ============================================================

// ── 1. Write Betweenness → Person.connector_score ─────────────
CALL gds.betweenness.write('opportunityGraph', {
  writeProperty: 'connector_score'
})
YIELD nodePropertiesWritten, computeMillis
RETURN
  'betweenness_centrality'          AS algorithm,
  'connector_score'                 AS property_written,
  nodePropertiesWritten,
  computeMillis                     AS compute_ms;


// ── 2. Write PageRank → *.influence_score ─────────────────────
CALL gds.pageRank.write('opportunityGraph', {
  dampingFactor:  0.85,
  maxIterations:  20,
  writeProperty:  'influence_score'
})
YIELD nodePropertiesWritten, computeMillis, ranIterations
RETURN
  'pagerank'                        AS algorithm,
  'influence_score'                 AS property_written,
  nodePropertiesWritten,
  ranIterations,
  computeMillis                     AS compute_ms;


// ── 3. Write Louvain → *.community_id ────────────────────────
CALL gds.louvain.write('opportunityGraph', {
  writeProperty:                  'community_id',
  includeIntermediateCommunities: false
})
YIELD nodePropertiesWritten, computeMillis, communityCount
RETURN
  'louvain'                         AS algorithm,
  'community_id'                    AS property_written,
  nodePropertiesWritten,
  communityCount                    AS communities_detected,
  computeMillis                     AS compute_ms;


// ── 4. Write Node Similarity → SIMILAR_TO relationships ────────
// Idempotent: MERGE prevents duplicates.
// Writes similarity_score on the SIMILAR_TO relationship and
// sets Property.similarity_score to the max score for that node.
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
  AND id(a) < id(b)
MERGE (a)-[r:SIMILAR_TO]-(b)
SET r.similarity_score = round(similarity, 4),
    r.computed_at      = datetime()
WITH a, b, similarity
// Also set max similarity_score on each Property node for quick filtering
SET a.similarity_score = CASE
  WHEN a.similarity_score IS NULL OR similarity > a.similarity_score
  THEN round(similarity, 4)
  ELSE a.similarity_score
END
SET b.similarity_score = CASE
  WHEN b.similarity_score IS NULL OR similarity > b.similarity_score
  THEN round(similarity, 4)
  ELSE b.similarity_score
END
RETURN COUNT(*) AS similar_to_relationships_written;


// ── 5. Compute and Write gravity_score to Property ─────────────
// gravity_score measures the "pull" a property exerts in the network.
// It combines GDS output scores into a single composite metric.
//
// Formula:
//   gravity_score =
//     0.30 × proof_influence      (ProofProject.influence_score of nearest proof node)
//     0.25 × network_centrality   (Property.connector_score, normalized)
//     0.20 × similarity_pull      (max SIMILAR_TO similarity_score)
//     0.15 × cluster_density      (community property_count, normalized)
//     0.10 × activation_pull      (VIEWED/REPORT/INSPECTION engagement signal)
//
// NOTE: This is a placeholder — full implementation requires the scoring
// engine to compute proof_influence and cluster_density from the graph.
// The formula is provided here for documentation and future automation.

// Step 5a: gather raw components per property
MATCH (pr:Property)
// Proof influence: nearest ProofProject's influence_score
OPTIONAL MATCH (pr)-[:PROOF_NEAR]->(pp:ProofProject)
WITH pr, MAX(COALESCE(pp.influence_score, 0)) AS proof_influence

// Network centrality: normalized connector_score
WITH pr, proof_influence,
     COALESCE(pr.connector_score, 0) AS raw_centrality

// Similarity pull: max similarity_score across SIMILAR_TO edges
OPTIONAL MATCH (pr)-[sim:SIMILAR_TO]-()
WITH pr, proof_influence, raw_centrality,
     MAX(COALESCE(sim.similarity_score, 0)) AS similarity_pull

// Activation pull: engagement signal from scored engine
WITH pr, proof_influence, raw_centrality, similarity_pull,
     COALESCE(pr.score_engagement_signal, 0) / 100.0 AS activation_pull

// Cluster density: approximated from community property count
MATCH (peer:Property)
WHERE peer.community_id IS NOT NULL AND peer.community_id = pr.community_id
WITH pr, proof_influence, raw_centrality, similarity_pull, activation_pull,
     COUNT(peer) AS cluster_size

// Normalize centrality (rough max 1000 for betweenness; tune as needed)
WITH pr, proof_influence, raw_centrality, similarity_pull, activation_pull,
     cluster_size,
     raw_centrality / 1000.0           AS norm_centrality,
     CASE WHEN cluster_size > 20 THEN 1.0 ELSE cluster_size / 20.0 END AS norm_cluster

// Compute gravity_score
WITH pr,
     round(
       0.30 * proof_influence   +
       0.25 * norm_centrality   +
       0.20 * similarity_pull   +
       0.15 * norm_cluster      +
       0.10 * activation_pull
     , 4) AS gravity_score

SET pr.gravity_score = gravity_score
RETURN COUNT(pr) AS properties_scored,
       round(AVG(gravity_score), 4) AS avg_gravity_score,
       round(MAX(gravity_score), 4) AS max_gravity_score;


// ── 6. Verify all write-backs ──────────────────────────────────

MATCH (p:Person)
WHERE p.connector_score IS NOT NULL
RETURN 'connector_score' AS property,
       COUNT(p)          AS nodes_with_value,
       round(MAX(p.connector_score), 2) AS max_value
UNION ALL
MATCH (n)
WHERE n.influence_score IS NOT NULL
  AND any(l IN labels(n) WHERE l IN ['Person','Property','ProofProject'])
RETURN 'influence_score'  AS property,
       COUNT(n)           AS nodes_with_value,
       round(MAX(n.influence_score), 5) AS max_value
UNION ALL
MATCH (n)
WHERE n.community_id IS NOT NULL
RETURN 'community_id'     AS property,
       COUNT(n)           AS nodes_with_value,
       toFloat(COUNT(DISTINCT n.community_id)) AS max_value
UNION ALL
MATCH (pr:Property)
WHERE pr.similarity_score IS NOT NULL
RETURN 'similarity_score' AS property,
       COUNT(pr)          AS nodes_with_value,
       round(MAX(pr.similarity_score), 4) AS max_value
UNION ALL
MATCH (pr:Property)
WHERE pr.gravity_score IS NOT NULL
RETURN 'gravity_score'    AS property,
       COUNT(pr)          AS nodes_with_value,
       round(MAX(pr.gravity_score), 4) AS max_value;

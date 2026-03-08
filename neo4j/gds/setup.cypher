// ============================================================
// Neo4j Graph Data Science — Opportunity Intelligence System
// ============================================================
// Run these scripts in order against your Neo4j database.
// Requires: Neo4j GDS plugin >= 2.x
//
// Named projection: opportunityGraph
// Nodes:  Person · Property · ProofProject · Market
// Rels:   OWNS · CONNECTED_TO · LOCATED_IN · SIMILAR_TO · PROOF_NEAR
//
// Relationship weight model (for Dijkstra):
//   TRUSTS              → 1  (strongest path)
//   CONNECTED_TO_PROOF  → 1
//   CONNECTED_TO        → 2
//   OWNS                → 3
//   LOCATED_IN          → 4
//   SIMILAR_TO          → 4
// ============================================================


// ── Step 0: Drop existing projection if present ────────────────
CALL gds.graph.exists('opportunityGraph')
YIELD exists
WHERE exists
CALL gds.graph.drop('opportunityGraph')
YIELD graphName
RETURN graphName;


// ── Step 1: Create named in-memory graph projection ───────────
//
// opportunityGraph captures Person, Property, ProofProject, Market
// with the five relationship types used across all GDS algorithms.
// Relationships are projected UNDIRECTED so community detection and
// path-finding work across all traversal directions.
CALL gds.graph.project(
  'opportunityGraph',
  // ── Node projections ─────────────────────────────────────────
  {
    Person: {
      properties: ['trust_score', 'influence_score', 'connector_score',
                   'community_id', 'opportunity_score']
    },
    Property: {
      properties: ['opportunity_score', 'estimated_value', 'roof_age',
                   'influence_score', 'connector_score', 'community_id']
    },
    ProofProject: {
      properties: ['influence_score', 'community_id']
    },
    Market: {
      properties: ['storm_risk_score', 'community_id']
    }
  },
  // ── Relationship projections ──────────────────────────────────
  {
    OWNS: {
      orientation: 'UNDIRECTED',
      properties: { weight: { defaultValue: 3.0 } }
    },
    CONNECTED_TO: {
      orientation: 'UNDIRECTED',
      // Use strength property if present, else default weight 2
      properties: {
        weight: { property: 'strength', defaultValue: 2.0 }
      }
    },
    LOCATED_IN: {
      orientation: 'UNDIRECTED',
      properties: { weight: { defaultValue: 4.0 } }
    },
    SIMILAR_TO: {
      orientation: 'UNDIRECTED',
      properties: {
        weight:           { defaultValue: 4.0 },
        similarity_score: { defaultValue: 0.0 }
      }
    },
    PROOF_NEAR: {
      orientation: 'UNDIRECTED',
      properties: { weight: { defaultValue: 2.0 } }
    }
  }
)
YIELD graphName, nodeCount, relationshipCount
RETURN graphName, nodeCount, relationshipCount;


// ── Step 2: Betweenness Centrality ────────────────────────────
// "Who actually connects clusters?"
// Bridge nodes: brokers, community figures, deal-enablers.
// Writes: Person.connector_score · Property.connector_score

CALL gds.betweenness.write('opportunityGraph', {
  writeProperty: 'connector_score'
})
YIELD nodePropertiesWritten, computeMillis
RETURN 'betweenness' AS algorithm, nodePropertiesWritten, computeMillis;


// ── Step 3: PageRank ──────────────────────────────────────────
// "Who has the most network influence?"
// Importance flows from important nodes.
// Writes: Person.influence_score · Property.influence_score · ProofProject.influence_score

CALL gds.pageRank.write('opportunityGraph', {
  dampingFactor:    0.85,
  maxIterations:    20,
  writeProperty:    'influence_score'
})
YIELD nodePropertiesWritten, computeMillis, ranIterations
RETURN 'pagerank' AS algorithm, nodePropertiesWritten, computeMillis, ranIterations;


// ── Step 4: Louvain Community Detection ───────────────────────
// "Which hidden ecosystems exist in the graph?"
// Lewisville retail cluster · broker-centered networks · Chabad-linked groups.
// Writes: Person.community_id · Property.community_id · Market.community_id

CALL gds.louvain.write('opportunityGraph', {
  writeProperty:        'community_id',
  includeIntermediateCommunities: false
})
YIELD nodePropertiesWritten, computeMillis, communityCount
RETURN 'louvain' AS algorithm, nodePropertiesWritten, computeMillis, communityCount;


// ── Step 5: Node Similarity → SIMILAR_TO relationships ────────
// "Show me more like this."
// Jaccard similarity on shared graph neighbors.
// Creates SIMILAR_TO relationships between similar Properties and Persons.
// similarity_score ranges 0.0 – 1.0 (higher = more similar).

// 5a. Property–Property similarity (shared LOCATED_IN → Market targets)
CALL gds.nodeSimilarity.write('opportunityGraph', {
  writeRelationshipType: 'SIMILAR_TO',
  writeProperty:         'similarity_score',
  similarityCutoff:      0.3,
  topK:                  5
})
YIELD nodesCompared, relationshipsWritten, computeMillis
RETURN 'nodeSimilarity_properties' AS algorithm, nodesCompared, relationshipsWritten, computeMillis;


// ── Step 6: Verify write-back results ─────────────────────────

// Top connectors (betweenness)
MATCH (p:Person)
WHERE p.connector_score IS NOT NULL AND p.connector_score > 0
RETURN p.name AS name, round(p.connector_score, 2) AS connector_score
ORDER BY p.connector_score DESC
LIMIT 10;

// Top influencers (pagerank)
MATCH (n)
WHERE n.influence_score IS NOT NULL
  AND any(l IN labels(n) WHERE l IN ['Person','Property','ProofProject'])
RETURN labels(n)[0] AS type, n.name AS name, round(n.influence_score, 5) AS influence_score
ORDER BY n.influence_score DESC
LIMIT 15;

// Community breakdown
MATCH (n)
WHERE n.community_id IS NOT NULL
RETURN n.community_id AS community_id,
       COUNT(n) AS size,
       COLLECT(DISTINCT labels(n)[0]) AS types,
       COLLECT(n.name)[..4] AS sample_names
ORDER BY size DESC
LIMIT 15;

// SIMILAR_TO relationships created
MATCH ()-[r:SIMILAR_TO]->()
WHERE r.similarity_score IS NOT NULL
RETURN COUNT(r) AS total_similar_pairs,
       round(AVG(r.similarity_score), 3) AS avg_similarity,
       round(MAX(r.similarity_score), 3) AS max_similarity;


// ── Step 7: Weighted Dijkstra — Best Path ─────────────────────
// "What is the best path to this owner?"
// Uses the relationship weights from the graph projection.
// Weight model: TRUSTS/PROOF_NEAR=2 · CONNECTED_TO=2 · OWNS=3 · LOCATED_IN=4 · SIMILAR_TO=4
// Lower total cost = warmer, more trusted introduction path.
//
// Example: best path from Mendel Johnson to a target owner
//
// Replace $sourceNodeId and $targetNodeId with actual Neo4j node IDs.

// ── 7a. Stream result (for API / exploration) ──────────────────
MATCH (source:Person {name: 'Mendel Johnson'})
MATCH (target:Person)  // Replace with specific target
WHERE target <> source
CALL gds.shortestPath.dijkstra.stream('opportunityGraph', {
  sourceNode:                 id(source),
  targetNode:                 id(target),
  relationshipWeightProperty: 'weight'
})
YIELD index, sourceNode, targetNode, totalCost, nodeIds, costs, path
RETURN
  [nId IN nodeIds | gds.util.asNode(nId).name] AS path_names,
  [nId IN nodeIds | labels(gds.util.asNode(nId))[0]] AS path_types,
  costs                                          AS hop_costs,
  round(totalCost, 2)                           AS path_cost;


// ── 7b. Yen's k-Shortest Paths (top 3 alternatives) ───────────
MATCH (source:Person {name: 'Mendel Johnson'})
MATCH (target:Person)  // Replace with specific target
WHERE target <> source
CALL gds.shortestPath.yens.stream('opportunityGraph', {
  sourceNode:                 id(source),
  targetNode:                 id(target),
  relationshipWeightProperty: 'weight',
  k:                          3
})
YIELD index, sourceNode, targetNode, totalCost, nodeIds, costs, path
RETURN
  index + 1                                      AS rank,
  [nId IN nodeIds | gds.util.asNode(nId).name]  AS path_names,
  costs                                          AS hop_costs,
  round(totalCost, 2)                           AS path_cost
ORDER BY totalCost;


// ── Step 8: Cleanup (drop projection when done) ────────────────
// Run this after writing back scores to free memory.
CALL gds.graph.drop('opportunityGraph', false)
YIELD graphName
RETURN graphName + ' projection dropped' AS result;

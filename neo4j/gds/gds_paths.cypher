// ============================================================
// GDS Weighted Pathfinding — Dijkstra & Yen's k-Shortest Paths
// ============================================================
// "What is the best path to this owner?"
//
// Uses relationship weights from opportunityGraph projection:
//   CONNECTED_TO  → weight 2  (or strength property if present)
//   PROOF_NEAR    → weight 2
//   OWNS          → weight 3
//   LOCATED_IN    → weight 4
//   SIMILAR_TO    → weight 4
//
// Lower total path_cost = warmer, more trusted introduction path.
// ============================================================
// Prereq: run gds_projection.cypher first.
// ============================================================

// ── Best Path: Mendel Johnson → target owner ──────────────────
// Replace target name / ID with your actual target.
// Returns: path_nodes, path_relationships, path_cost per hop.
MATCH (source:Person {name: 'Mendel Johnson'})
MATCH (target:Person {name: 'TARGET_OWNER_NAME'})  // ← replace
WHERE source <> target
CALL gds.shortestPath.dijkstra.stream('opportunityGraph', {
  sourceNode:                 id(source),
  targetNode:                 id(target),
  relationshipWeightProperty: 'weight'
})
YIELD index, sourceNode, targetNode, totalCost, nodeIds, costs, path
RETURN
  // Source and target
  gds.util.asNode(sourceNode).name                               AS source,
  gds.util.asNode(targetNode).name                               AS target,
  // Path as ordered list of node names
  [nId IN nodeIds | gds.util.asNode(nId).name]                  AS path_nodes,
  // Path relationship types (one fewer than nodes)
  [r IN relationships(path) | type(r)]                          AS path_relationships,
  // Cost at each hop
  costs                                                         AS hop_costs,
  // Total weighted path cost
  round(totalCost, 2)                                           AS path_cost;


// ── Yen's k-Shortest Paths: top 3 alternatives ────────────────
// Useful when the single shortest path is blocked or suboptimal.
// Returns 3 ranked paths so you can choose by context.
MATCH (source:Person {name: 'Mendel Johnson'})
MATCH (target:Person {name: 'TARGET_OWNER_NAME'})  // ← replace
WHERE source <> target
CALL gds.shortestPath.yens.stream('opportunityGraph', {
  sourceNode:                 id(source),
  targetNode:                 id(target),
  k:                          3,
  relationshipWeightProperty: 'weight'
})
YIELD index, sourceNode, targetNode, totalCost, nodeIds, costs, path
RETURN
  index + 1                                                     AS rank,
  gds.util.asNode(sourceNode).name                              AS source,
  gds.util.asNode(targetNode).name                              AS target,
  [nId IN nodeIds | gds.util.asNode(nId).name]                 AS path_nodes,
  [r IN relationships(path) | type(r)]                         AS path_relationships,
  costs                                                         AS hop_costs,
  round(totalCost, 2)                                          AS path_cost
ORDER BY totalCost ASC;


// ── Path from ProofProject → target Property ──────────────────
// Find how close a proof node is to a high-opportunity property.
// Useful for proof-proximity scoring and outreach targeting.
MATCH (source:ProofProject)
MATCH (target:Property)
WHERE target.opportunity_score >= 70
WITH source, target
ORDER BY target.opportunity_score DESC
LIMIT 5
CALL gds.shortestPath.dijkstra.stream('opportunityGraph', {
  sourceNode:                 id(source),
  targetNode:                 id(target),
  relationshipWeightProperty: 'weight'
})
YIELD totalCost, nodeIds, costs, path
RETURN
  source.name                                                   AS proof_project,
  target.name                                                   AS opportunity_property,
  target.opportunity_score                                      AS opportunity_score,
  [nId IN nodeIds | gds.util.asNode(nId).name]                 AS path_nodes,
  [r IN relationships(path) | type(r)]                         AS path_relationships,
  round(totalCost, 2)                                          AS path_cost
ORDER BY path_cost ASC, opportunity_score DESC
LIMIT 10;


// ── All-pairs paths from a connector to high-score owners ──────
// Given a connector (e.g. Mendel), find optimal paths to all
// high-opportunity property owners, ranked by path cost.
MATCH (connector:Person {name: 'Mendel Johnson'})
MATCH (owner:Person)-[:OWNS]->(pr:Property)
WHERE pr.opportunity_score >= 70
  AND owner <> connector
WITH DISTINCT connector, owner, pr
// Limit to 10 targets to keep runtime bounded
ORDER BY pr.opportunity_score DESC
LIMIT 10
CALL gds.shortestPath.dijkstra.stream('opportunityGraph', {
  sourceNode:                 id(connector),
  targetNode:                 id(owner),
  relationshipWeightProperty: 'weight'
})
YIELD totalCost, nodeIds, path
RETURN
  connector.name                                                AS source,
  owner.name                                                    AS target,
  pr.name                                                       AS target_property,
  pr.opportunity_score                                          AS opportunity_score,
  [nId IN nodeIds | gds.util.asNode(nId).name]                 AS path_nodes,
  [r IN relationships(path) | type(r)]                         AS path_relationships,
  round(totalCost, 2)                                          AS path_cost
ORDER BY path_cost ASC;

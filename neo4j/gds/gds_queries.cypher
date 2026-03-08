// ============================================================
// GDS Dashboard Queries
// Requires: gds_writeback.cypher to have been run so that
// connector_score, influence_score, community_id, similarity_score,
// and gravity_score are present as node properties.
// ============================================================


// ── Connector Ranking ──────────────────────────────────────────
// Top 25 bridge connectors — people who unlock other people.
// Sorted by connector_score (betweenness) then influence_score (pagerank).
MATCH (p:Person)
WHERE p.connector_score IS NOT NULL
RETURN
  p.name                                           AS name,
  p.role                                           AS role,
  round(p.connector_score, 2)                      AS connector_score,
  round(COALESCE(p.influence_score, 0), 5)         AS influence_score,
  p.trust_score                                    AS trust_score,
  p.email                                          AS email,
  COALESCE(p.community_id, -1)                     AS community_id,
  SIZE([(p)-[:CONNECTED_TO]-() | 1])               AS direct_connections,
  SIZE([(p)-[:OWNS]->(:Property) | 1])             AS properties_owned
ORDER BY p.connector_score DESC, p.influence_score DESC
LIMIT 25;


// ── Community Query ────────────────────────────────────────────
// Top communities by size, with people/property breakdowns.
MATCH (n)
WHERE n.community_id IS NOT NULL
  AND any(l IN labels(n) WHERE l IN ['Person','Property','Market'])
WITH n.community_id                                          AS community_id,
     COUNT(n)                                               AS node_count,
     SIZE([x IN COLLECT(n) WHERE labels(x)[0]='Person'])   AS people_count,
     SIZE([x IN COLLECT(n) WHERE labels(x)[0]='Property']) AS property_count,
     [x IN COLLECT(n) WHERE labels(x)[0]='Market' | x.name][0]
                                                            AS dominant_market,
     [x IN COLLECT(n) | x.name][..5]                       AS sample_names
RETURN
  community_id,
  node_count,
  people_count,
  property_count,
  dominant_market,
  sample_names
ORDER BY node_count DESC
LIMIT 20;


// ── Similarity Query ───────────────────────────────────────────
// Top 20 properties most similar to a given property or proof project.
// Replace $sourceName with the target property or proof project name.
MATCH (source:Property {name: $sourceName})          // or :ProofProject
MATCH (source)-[sim:SIMILAR_TO]-(similar:Property)
OPTIONAL MATCH (similar)-[:LOCATED_IN]->(m:Market)
RETURN
  source.name                                        AS source_property,
  similar.name                                       AS similar_property,
  round(sim.similarity_score, 3)                     AS similarity_score,
  COALESCE(m.name, '—')                              AS market,
  COALESCE(similar.asset_type, '—')                  AS asset_type,
  similar.opportunity_score                          AS opportunity_score,
  similar.estimated_value                            AS estimated_value,
  similar.roof_condition                             AS roof_condition
ORDER BY sim.similarity_score DESC
LIMIT 20;


// ── Best Path Query ───────────────────────────────────────────
// Weighted shortest path from source person to target owner.
// Prereq: opportunityGraph projection must be loaded.
// Replace $sourceName and $targetName with actual person names.
MATCH (source:Person {name: $sourceName})
MATCH (target:Person {name: $targetName})
WHERE source <> target
CALL gds.shortestPath.dijkstra.stream('opportunityGraph', {
  sourceNode:                 id(source),
  targetNode:                 id(target),
  relationshipWeightProperty: 'weight'
})
YIELD totalCost, nodeIds, costs, path
RETURN
  source.name                                        AS source,
  target.name                                        AS target,
  round(totalCost, 2)                               AS path_cost,
  [nId IN nodeIds | gds.util.asNode(nId).name]     AS path_nodes,
  [r IN relationships(path) | type(r)]              AS path_relationships,
  costs                                             AS hop_costs;


// ── Opportunity Cluster Query ──────────────────────────────────
// Markets / communities with the strongest opportunity density.
// Combines community detection output with property opportunity scores.
MATCH (pr:Property)
WHERE pr.community_id IS NOT NULL
  AND pr.opportunity_score IS NOT NULL
OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
WITH pr.community_id                               AS community_id,
     COALESCE(m.name, 'Unknown')                  AS market,
     COUNT(pr)                                    AS property_count,
     AVG(pr.opportunity_score)                    AS avg_opportunity_score,
     SUM(pr.estimated_value)                      AS total_estimated_value,
     MAX(pr.opportunity_score)                    AS max_score,
     COLLECT(pr.name)[..4]                        AS sample_properties
RETURN
  community_id,
  market,
  property_count,
  round(avg_opportunity_score, 1)                AS avg_opportunity_score,
  total_estimated_value,
  round(max_score, 1)                            AS max_score,
  sample_properties
ORDER BY avg_opportunity_score DESC, property_count DESC
LIMIT 15;


// ── Gravity Score Leaderboard ──────────────────────────────────
// Properties with the highest composite gravity_score.
// gravity_score = network pull × proof proximity × cluster density.
MATCH (pr:Property)
WHERE pr.gravity_score IS NOT NULL
OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
RETURN
  pr.name                                        AS property,
  COALESCE(m.name, '—')                         AS market,
  COALESCE(pr.asset_type, '—')                  AS asset_type,
  round(pr.gravity_score, 4)                    AS gravity_score,
  round(COALESCE(pr.opportunity_score, 0), 1)   AS opportunity_score,
  round(COALESCE(pr.influence_score, 0), 5)     AS influence_score,
  round(COALESCE(pr.similarity_score, 0), 3)    AS similarity_score,
  COALESCE(pr.community_id, -1)                 AS community_id,
  COALESCE(owner.name, '—')                     AS owner
ORDER BY pr.gravity_score DESC
LIMIT 20;

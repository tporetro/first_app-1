// ============================================================
// Neo4j Opportunity Intelligence System
// Intelligence Query Library — 15 Queries
// Each query has: comment header, Cypher, short description
// ============================================================


// ------------------------------------------------------------
// QUERY 01: Top Opportunity Properties
// Description: Returns the 20 highest-scoring properties ranked
// by composite opportunity_score, with key context fields for
// triage and prioritization.
// ------------------------------------------------------------
// USAGE: Run after scoring_engine.cypher to get fresh rankings.
MATCH (pr:Property)
OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
RETURN
  pr.property_id                    AS property_id,
  pr.name                           AS property_name,
  pr.address                        AS address,
  pr.city                           AS city,
  pr.state                          AS state,
  pr.asset_type                     AS asset_type,
  pr.building_sqft                  AS building_sqft,
  pr.roof_age                       AS roof_age,
  pr.roof_condition                 AS roof_condition,
  pr.estimated_value                AS estimated_value,
  pr.opportunity_score              AS opportunity_score,
  pr.score_storm_signal             AS storm_signal,
  pr.score_damage_probability       AS damage_probability,
  pr.score_asset_value              AS asset_value,
  pr.score_proof_proximity          AS proof_proximity,
  pr.score_network_reachability     AS network_reachability,
  pr.score_engagement_signal        AS engagement_signal,
  m.name                            AS market
ORDER BY pr.opportunity_score DESC
LIMIT 20;


// ------------------------------------------------------------
// QUERY 02: Highest Value Opportunities
// Description: Properties where both estimated_value and
// opportunity_score are high — the "big fish" targets.
// ------------------------------------------------------------
MATCH (pr:Property)
OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
WHERE pr.opportunity_score >= 60
  AND pr.estimated_value   >= 3000000
RETURN
  pr.property_id        AS property_id,
  pr.name               AS property_name,
  pr.asset_type         AS asset_type,
  pr.estimated_value    AS estimated_value,
  pr.opportunity_score  AS opportunity_score,
  pr.occupancy_rate     AS occupancy_rate,
  pr.noi                AS noi,
  pr.cap_rate           AS cap_rate,
  m.name                AS market,
  owner.name            AS owner_name,
  owner.email           AS owner_email
ORDER BY pr.estimated_value * pr.opportunity_score DESC
LIMIT 15;


// ------------------------------------------------------------
// QUERY 03: Properties Hit by the Strongest Storms
// Description: Returns properties with the highest storm exposure,
// ranked by cumulative severity and damage across all events.
// ------------------------------------------------------------
MATCH (pr:Property)-[ab:AFFECTED_BY]->(s:StormEvent)
WITH pr,
     COUNT(s)          AS storm_count,
     SUM(s.severity)   AS total_severity,
     MAX(s.severity)   AS max_severity,
     MAX(s.hail_size)  AS max_hail_size,
     COLLECT(s.name)   AS storm_names,
     SUM(ab.claim_amount) AS total_claims
RETURN
  pr.property_id        AS property_id,
  pr.name               AS property_name,
  pr.city               AS city,
  pr.state              AS state,
  pr.asset_type         AS asset_type,
  pr.roof_age           AS roof_age,
  pr.opportunity_score  AS opportunity_score,
  storm_count,
  total_severity,
  max_severity,
  max_hail_size,
  storm_names,
  total_claims
ORDER BY total_severity DESC, max_hail_size DESC
LIMIT 15;


// ------------------------------------------------------------
// QUERY 04: Owners with the Most Properties
// Description: Identifies portfolio owners — people or companies
// with multiple holdings, enabling portfolio-level outreach.
// ------------------------------------------------------------
MATCH (owner)-[:OWNS]->(pr:Property)
WHERE owner:Person OR owner:Company
WITH owner,
     LABELS(owner)[0]               AS owner_type,
     COUNT(pr)                       AS property_count,
     SUM(pr.estimated_value)         AS portfolio_value,
     AVG(pr.opportunity_score)       AS avg_opportunity_score,
     COLLECT(pr.name)[..5]           AS sample_properties
RETURN
  CASE WHEN owner:Person THEN owner.name ELSE owner.name END AS owner_name,
  owner_type,
  CASE WHEN owner:Person THEN owner.email ELSE '' END        AS email,
  CASE WHEN owner:Person THEN owner.phone ELSE '' END        AS phone,
  property_count,
  portfolio_value,
  round(avg_opportunity_score, 1)  AS avg_opportunity_score,
  sample_properties
ORDER BY property_count DESC, portfolio_value DESC
LIMIT 20;


// ------------------------------------------------------------
// QUERY 05: Owners Connected to Proof Projects
// Description: Finds property owners who have already completed
// at least one successful renovation — warm relationship signal.
// ------------------------------------------------------------
MATCH (pr:Property)
OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
OPTIONAL MATCH (pp:ProofProject)-[:COMPLETED_BY]->(owner)
WITH pr, owner, COUNT(pp) AS proof_count, COLLECT(pp.name) AS project_names
WHERE proof_count > 0
RETURN
  pr.property_id        AS property_id,
  pr.name               AS property_name,
  pr.opportunity_score  AS opportunity_score,
  pr.asset_type         AS asset_type,
  owner.name            AS owner_name,
  owner.email           AS owner_email,
  proof_count,
  project_names
ORDER BY proof_count DESC, pr.opportunity_score DESC
LIMIT 15;


// ------------------------------------------------------------
// QUERY 06: Shortest Trust Path to Owner
// Description: For a given target property, finds the shortest
// CONNECTED_TO path from any known User → Person → owner.
// Reveals who in the network can make the warm introduction.
// Usage: Replace PR012 with any target property_id.
// ------------------------------------------------------------
MATCH (target:Property { property_id: 'PR012' })
MATCH (owner:Person)-[:OWNS]->(target)
MATCH (connector:Person)
  WHERE connector.person_id <> owner.person_id
WITH target, owner, connector
MATCH path = shortestPath(
  (connector)-[:CONNECTED_TO*1..4]->(owner)
)
WHERE LENGTH(path) > 0
RETURN
  owner.name                         AS owner_name,
  owner.email                        AS owner_email,
  connector.name                     AS entry_point,
  connector.trust_score              AS entry_trust_score,
  [n IN NODES(path) | n.name]        AS path_names,
  LENGTH(path)                       AS path_length
ORDER BY path_length ASC, connector.trust_score DESC
LIMIT 10;


// ------------------------------------------------------------
// QUERY 07: Properties Near Proof Projects
// Description: Surfaces untouched properties that sit near a
// completed proof project — showing demonstrated ROI in market.
// ------------------------------------------------------------
MATCH (pp:ProofProject)-[pn:PROOF_NEAR]->(pr:Property)
WHERE pr.opportunity_score >= 55
RETURN
  pr.property_id         AS property_id,
  pr.name                AS property_name,
  pr.city                AS city,
  pr.asset_type          AS asset_type,
  pr.opportunity_score   AS opportunity_score,
  pr.roof_age            AS roof_age,
  pr.roof_condition      AS roof_condition,
  pp.name                AS nearby_proof_project,
  pp.roi                 AS proof_roi,
  pp.value_added         AS proof_value_added,
  pn.distance_miles      AS distance_miles,
  pn.same_asset_type     AS same_asset_type
ORDER BY pr.opportunity_score DESC, pn.distance_miles ASC
LIMIT 20;


// ------------------------------------------------------------
// QUERY 08: Markets with Highest Opportunity Density
// Description: Aggregates property opportunity scores by market
// to rank which geographies have the most active targets.
// ------------------------------------------------------------
MATCH (pr:Property)-[:LOCATED_IN]->(m:Market)
WITH m,
     COUNT(pr)                      AS property_count,
     AVG(pr.opportunity_score)      AS avg_score,
     MAX(pr.opportunity_score)      AS max_score,
     SUM(pr.estimated_value)        AS total_value,
     COUNT(CASE WHEN pr.opportunity_score >= 75 THEN 1 END) AS high_score_count
RETURN
  m.market_id             AS market_id,
  m.name                  AS market_name,
  m.state                 AS state,
  m.storm_risk_score      AS storm_risk_score,
  m.hail_events_5yr       AS hail_events_5yr,
  property_count,
  round(avg_score, 1)     AS avg_opportunity_score,
  max_score               AS max_opportunity_score,
  high_score_count        AS properties_score_75plus,
  total_value             AS total_portfolio_value
ORDER BY avg_score DESC, high_score_count DESC;


// ------------------------------------------------------------
// QUERY 09: Properties with Highest Engagement
// Description: Properties that users are actively viewing,
// reporting on, and requesting inspections for — hottest leads.
// ------------------------------------------------------------
MATCH (pr:Property)
OPTIONAL MATCH (:User)-[v:VIEWED_OPPORTUNITY]->(pr)
OPTIONAL MATCH (:User)-[g:GENERATED_REPORT]->(pr)
OPTIONAL MATCH (:User)-[i:REQUESTED_INSPECTION]->(pr)
WITH pr,
     COUNT(DISTINCT v) AS view_count,
     COUNT(DISTINCT g) AS report_count,
     COUNT(DISTINCT i) AS inspection_count,
     (COUNT(DISTINCT v) + COUNT(DISTINCT g)*3 + COUNT(DISTINCT i)*5) AS engagement_score
WHERE engagement_score > 0
RETURN
  pr.property_id        AS property_id,
  pr.name               AS property_name,
  pr.city               AS city,
  pr.asset_type         AS asset_type,
  pr.opportunity_score  AS opportunity_score,
  view_count,
  report_count,
  inspection_count,
  engagement_score
ORDER BY engagement_score DESC, pr.opportunity_score DESC
LIMIT 15;


// ------------------------------------------------------------
// QUERY 10: Referral Partners Generating Opportunities
// Description: Identifies brokers and connectors whose networks
// link to the most high-scoring properties — key channel partners.
// ------------------------------------------------------------
MATCH (connector:Person)-[:CONNECTED_TO]->(owner:Person)-[:OWNS]->(pr:Property)
WHERE pr.opportunity_score >= 60
  AND connector.role IN ['Broker', 'Property Manager', 'Developer', 'Analyst']
WITH connector,
     COUNT(DISTINCT pr)         AS opportunity_count,
     AVG(pr.opportunity_score)  AS avg_score,
     SUM(pr.estimated_value)    AS pipeline_value,
     COLLECT(DISTINCT pr.name)[..4] AS sample_opportunities
RETURN
  connector.person_id     AS person_id,
  connector.name          AS connector_name,
  connector.role          AS role,
  connector.email         AS email,
  connector.trust_score   AS trust_score,
  connector.influence_score AS influence_score,
  opportunity_count,
  round(avg_score, 1)     AS avg_opportunity_score,
  pipeline_value,
  sample_opportunities
ORDER BY opportunity_count DESC, pipeline_value DESC
LIMIT 15;


// ------------------------------------------------------------
// QUERY 11: Property Clusters with Repeated Storm Signals
// Description: Groups similar properties that have both been
// storm-affected and have high opportunity scores — cluster targets.
// ------------------------------------------------------------
MATCH (a:Property)-[:SIMILAR_TO]->(b:Property)
WHERE a.property_id < b.property_id
MATCH (a)-[:AFFECTED_BY]->(s1:StormEvent)
MATCH (b)-[:AFFECTED_BY]->(s2:StormEvent)
WITH a, b,
     COUNT(DISTINCT s1) AS a_storms,
     COUNT(DISTINCT s2) AS b_storms,
     a.opportunity_score AS a_score,
     b.opportunity_score AS b_score
WHERE a_score >= 60 AND b_score >= 60
RETURN
  a.property_id        AS property_a_id,
  a.name               AS property_a,
  a.city               AS city_a,
  a_score,
  a_storms,
  b.property_id        AS property_b_id,
  b.name               AS property_b,
  b.city               AS city_b,
  b_score,
  b_storms,
  (a_score + b_score) / 2.0 AS cluster_avg_score
ORDER BY cluster_avg_score DESC;


// ------------------------------------------------------------
// QUERY 12: Storm Events Producing the Most Opportunities
// Description: Ranks historical storm events by the number of
// high-scoring properties in their damage footprint.
// ------------------------------------------------------------
MATCH (s:StormEvent)<-[:AFFECTED_BY]-(pr:Property)
WITH s,
     COUNT(pr)                     AS affected_count,
     AVG(pr.opportunity_score)     AS avg_score,
     COUNT(CASE WHEN pr.opportunity_score >= 70 THEN 1 END) AS high_score_count,
     SUM(pr.estimated_value)       AS total_affected_value
RETURN
  s.storm_event_id     AS storm_id,
  s.name               AS storm_name,
  s.event_type         AS event_type,
  s.event_date         AS event_date,
  s.severity           AS severity,
  s.hail_size          AS hail_size,
  s.wind_speed         AS wind_speed,
  affected_count,
  round(avg_score, 1)  AS avg_opportunity_score,
  high_score_count     AS high_score_properties,
  total_affected_value
ORDER BY high_score_count DESC, avg_score DESC;


// ------------------------------------------------------------
// QUERY 13: Top Network Connectors
// Description: People who are central connectors in the ownership
// network — highest betweenness potential based on connections
// to multiple high-score property owners.
// ------------------------------------------------------------
MATCH (connector:Person)-[:CONNECTED_TO]->(peer:Person)
WITH connector,
     COUNT(DISTINCT peer)                      AS connection_count,
     AVG(peer.trust_score)                     AS avg_peer_trust,
     AVG(peer.influence_score)                 AS avg_peer_influence
OPTIONAL MATCH (connector)-[:CONNECTED_TO]->(owner:Person)-[:OWNS]->(pr:Property)
WITH connector,
     connection_count,
     avg_peer_trust,
     avg_peer_influence,
     COUNT(DISTINCT pr)           AS reachable_properties,
     AVG(pr.opportunity_score)    AS avg_reachable_score
RETURN
  connector.person_id          AS person_id,
  connector.name               AS name,
  connector.role               AS role,
  connector.email              AS email,
  connector.trust_score        AS trust_score,
  connector.influence_score    AS influence_score,
  connection_count,
  round(avg_peer_trust, 1)     AS avg_peer_trust,
  reachable_properties,
  round(avg_reachable_score,1) AS avg_reachable_opportunity_score
ORDER BY connection_count DESC, reachable_properties DESC
LIMIT 15;


// ------------------------------------------------------------
// QUERY 14: Recently Surfaced Opportunities
// Description: Properties that have had recent user engagement
// (views, reports, inspections) in the last 30 days — hot pipeline.
// ------------------------------------------------------------
WITH date() - duration('P30D') AS cutoff
MATCH (:User)-[act]->(pr:Property)
  WHERE TYPE(act) IN ['VIEWED_OPPORTUNITY','GENERATED_REPORT','REQUESTED_INSPECTION']
    AND act.action_date >= cutoff
WITH pr,
     COUNT(act)                        AS recent_actions,
     MAX(act.action_date)              AS last_activity,
     COLLECT(DISTINCT TYPE(act))       AS action_types
OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
RETURN
  pr.property_id        AS property_id,
  pr.name               AS property_name,
  pr.city               AS city,
  pr.asset_type         AS asset_type,
  pr.opportunity_score  AS opportunity_score,
  pr.estimated_value    AS estimated_value,
  m.name                AS market,
  owner.name            AS owner_name,
  owner.email           AS owner_email,
  recent_actions,
  last_activity,
  action_types
ORDER BY last_activity DESC, pr.opportunity_score DESC;


// ------------------------------------------------------------
// QUERY 15: Opportunity Score Breakdown for a Property
// Description: Full audit of every scoring component for a single
// property — use for detailed review, reporting, or debugging.
// Usage: Replace PR015 with any target property_id.
// ------------------------------------------------------------
MATCH (pr:Property { property_id: 'PR015' })
OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
OPTIONAL MATCH (pr)-[ab:AFFECTED_BY]->(s:StormEvent)
OPTIONAL MATCH (pp:ProofProject)-[:PROOF_NEAR]->(pr)
OPTIONAL MATCH (:User)-[v:VIEWED_OPPORTUNITY]->(pr)
OPTIONAL MATCH (:User)-[g:GENERATED_REPORT]->(pr)
OPTIONAL MATCH (:User)-[i:REQUESTED_INSPECTION]->(pr)
WITH pr, m, owner,
     COUNT(DISTINCT s)   AS storm_count,
     MAX(s.severity)     AS max_severity,
     MAX(s.hail_size)    AS max_hail,
     COUNT(DISTINCT pp)  AS proof_count,
     COUNT(DISTINCT v)   AS views,
     COUNT(DISTINCT g)   AS reports,
     COUNT(DISTINCT i)   AS inspections
RETURN
  pr.property_id                      AS property_id,
  pr.name                             AS property_name,
  pr.address                          AS address,
  pr.city                             AS city,
  pr.state                            AS state,
  pr.asset_type                       AS asset_type,
  pr.building_sqft                    AS building_sqft,
  pr.year_built                       AS year_built,
  pr.roof_type                        AS roof_type,
  pr.roof_age                         AS roof_age,
  pr.roof_condition                   AS roof_condition,
  pr.estimated_value                  AS estimated_value,
  pr.noi                              AS noi,
  pr.cap_rate                         AS cap_rate,
  pr.occupancy_rate                   AS occupancy_rate,
  m.name                              AS market,
  m.storm_risk_score                  AS market_storm_risk,
  owner.name                          AS owner_name,
  owner.email                         AS owner_email,
  owner.trust_score                   AS owner_trust_score,
  // --- Score components ---
  pr.opportunity_score                AS FINAL_OPPORTUNITY_SCORE,
  pr.score_storm_signal               AS component_storm_signal,
  pr.score_damage_probability         AS component_damage_probability,
  pr.score_asset_value                AS component_asset_value,
  pr.score_proof_proximity            AS component_proof_proximity,
  pr.score_network_reachability       AS component_network_reachability,
  pr.score_engagement_signal          AS component_engagement_signal,
  // --- Raw evidence ---
  storm_count,
  max_severity,
  max_hail,
  proof_count,
  views                               AS user_views,
  reports                             AS user_reports,
  inspections                         AS user_inspections;

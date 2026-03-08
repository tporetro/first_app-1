// ============================================================
// Neo4j Opportunity Intelligence System
// Dashboard Query Layer — Widget Queries
// Designed for direct consumption by the API / frontend widgets
// All queries return flat, visualization-ready result sets
// ============================================================


// ============================================================
// WIDGET 1: Top Opportunities
// Returns highest-scoring properties with owner and market context
// Fields: property, market, asset_type, opportunity_score,
//         estimated_value, owner
// ============================================================
MATCH (pr:Property)
OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
OPTIONAL MATCH (co:Company)-[:OWNS]->(pr)
RETURN
  pr.property_id                AS id,
  pr.name                       AS property,
  pr.address                    AS address,
  pr.city                       AS city,
  pr.state                      AS state,
  COALESCE(m.name, 'Unknown')   AS market,
  pr.asset_type                 AS asset_type,
  pr.building_sqft              AS building_sqft,
  pr.roof_age                   AS roof_age,
  pr.roof_condition             AS roof_condition,
  pr.opportunity_score          AS opportunity_score,
  pr.estimated_value            AS estimated_value,
  COALESCE(owner.name, co.name, 'Unknown')  AS owner,
  COALESCE(owner.email, '')     AS owner_email,
  COALESCE(owner.phone, '')     AS owner_phone,
  pr.score_storm_signal         AS score_storm,
  pr.score_damage_probability   AS score_damage,
  pr.score_asset_value          AS score_value,
  pr.score_proof_proximity      AS score_proof,
  pr.score_network_reachability AS score_network,
  pr.score_engagement_signal    AS score_engagement
ORDER BY pr.opportunity_score DESC
LIMIT 10;


// ============================================================
// WIDGET 2: Top Connectors
// People who can unlock the most high-scoring properties
// Fields: name, role, trust_score, connection_count,
//         reachable_properties, pipeline_value
// ============================================================
MATCH (connector:Person)-[:CONNECTED_TO]->(owner:Person)-[:OWNS]->(pr:Property)
WHERE pr.opportunity_score >= 55
WITH connector,
     COUNT(DISTINCT owner)          AS owners_reachable,
     COUNT(DISTINCT pr)             AS reachable_properties,
     SUM(pr.estimated_value)        AS pipeline_value,
     AVG(pr.opportunity_score)      AS avg_score,
     COLLECT(DISTINCT pr.name)[..3] AS sample_properties
OPTIONAL MATCH (connector)-[:CONNECTED_TO]->(peer:Person)
WITH connector, owners_reachable, reachable_properties,
     pipeline_value, avg_score, sample_properties,
     COUNT(DISTINCT peer) AS total_connections
RETURN
  connector.person_id          AS id,
  connector.name               AS name,
  connector.role               AS role,
  connector.email              AS email,
  connector.phone              AS phone,
  connector.trust_score        AS trust_score,
  connector.influence_score    AS influence_score,
  total_connections            AS connection_count,
  owners_reachable,
  reachable_properties,
  pipeline_value,
  round(avg_score, 1)          AS avg_opportunity_score,
  sample_properties
ORDER BY reachable_properties DESC, pipeline_value DESC
LIMIT 10;


// ============================================================
// WIDGET 3: Active Opportunity Clusters
// Property clusters sharing storm exposure and high scores
// Fields: cluster_id, market, asset_type, property_count,
//         avg_score, total_value, storm_count
// ============================================================
MATCH (pr:Property)-[:LOCATED_IN]->(m:Market)
MATCH (pr)-[:AFFECTED_BY]->(s:StormEvent)
WHERE pr.opportunity_score >= 60
WITH m, pr.asset_type AS asset_type,
     COUNT(DISTINCT pr)            AS property_count,
     AVG(pr.opportunity_score)     AS avg_score,
     SUM(pr.estimated_value)       AS total_value,
     COUNT(DISTINCT s)             AS storm_event_count,
     COLLECT(DISTINCT pr.name)[..4] AS sample_properties
WHERE property_count >= 2
RETURN
  m.market_id         AS market_id,
  m.name              AS market,
  m.state             AS state,
  m.storm_risk_score  AS market_storm_risk,
  asset_type,
  property_count,
  round(avg_score, 1) AS avg_opportunity_score,
  total_value,
  storm_event_count,
  sample_properties
ORDER BY avg_score DESC, property_count DESC;


// ============================================================
// WIDGET 4: Opportunity Pipeline
// Full pipeline view: counts and values by score tier
// Fields: tier, property_count, total_value, avg_score
// ============================================================
MATCH (pr:Property)
WITH pr,
  CASE
    WHEN pr.opportunity_score >= 85 THEN 'HOT (85-100)'
    WHEN pr.opportunity_score >= 70 THEN 'WARM (70-84)'
    WHEN pr.opportunity_score >= 55 THEN 'ACTIVE (55-69)'
    WHEN pr.opportunity_score >= 40 THEN 'WATCH (40-54)'
    ELSE                                 'COLD (<40)'
  END AS tier,
  CASE
    WHEN pr.opportunity_score >= 85 THEN 1
    WHEN pr.opportunity_score >= 70 THEN 2
    WHEN pr.opportunity_score >= 55 THEN 3
    WHEN pr.opportunity_score >= 40 THEN 4
    ELSE                                 5
  END AS tier_order
WITH tier, tier_order,
     COUNT(pr)                  AS property_count,
     SUM(pr.estimated_value)    AS total_value,
     AVG(pr.opportunity_score)  AS avg_score,
     MAX(pr.opportunity_score)  AS max_score
RETURN
  tier,
  property_count,
  total_value,
  round(avg_score, 1) AS avg_score,
  max_score
ORDER BY tier_order ASC;


// ============================================================
// WIDGET 5: Best Next Actions
// Surfaces specific actionable items across the pipeline:
// pending inspections, unfiled claims, absentee owners,
// aged roofs with no engagement
// Fields: action_type, property, owner, urgency, reason
// ============================================================

// 5a — Pending insurance claims (immediate)
MATCH (pr:Property)-[ab:AFFECTED_BY]->(s:StormEvent)
WHERE ab.claim_status = 'Pending'
  AND pr.opportunity_score >= 60
OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
RETURN
  'PENDING_CLAIM'              AS action_type,
  pr.property_id               AS property_id,
  pr.name                      AS property_name,
  pr.city                      AS city,
  pr.opportunity_score         AS opportunity_score,
  pr.estimated_value           AS estimated_value,
  COALESCE(owner.name, 'N/A')  AS owner_name,
  COALESCE(owner.email,'N/A')  AS owner_email,
  'HIGH'                       AS urgency,
  'Storm claim pending — owner engagement window open' AS reason

UNION ALL

// 5b — Unfiled claims (high conversion)
MATCH (pr:Property)-[ab:AFFECTED_BY]->(s:StormEvent)
WHERE ab.claim_filed = false
  AND pr.opportunity_score >= 65
OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
RETURN
  'UNFILED_CLAIM'              AS action_type,
  pr.property_id               AS property_id,
  pr.name                      AS property_name,
  pr.city                      AS city,
  pr.opportunity_score         AS opportunity_score,
  pr.estimated_value           AS estimated_value,
  COALESCE(owner.name, 'N/A')  AS owner_name,
  COALESCE(owner.email,'N/A')  AS owner_email,
  'HIGH'                       AS urgency,
  'Storm damage unfiled — proactive outreach opportunity' AS reason

UNION ALL

// 5c — Critical roofs with no inspection scheduled
MATCH (pr:Property)
WHERE pr.roof_condition = 'Critical'
  AND pr.opportunity_score >= 70
  AND NOT EXISTS {
    MATCH (:User)-[:REQUESTED_INSPECTION]->(pr)
  }
OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
RETURN
  'INSPECTION_NEEDED'          AS action_type,
  pr.property_id               AS property_id,
  pr.name                      AS property_name,
  pr.city                      AS city,
  pr.opportunity_score         AS opportunity_score,
  pr.estimated_value           AS estimated_value,
  COALESCE(owner.name, 'N/A')  AS owner_name,
  COALESCE(owner.email,'N/A')  AS owner_email,
  'MEDIUM'                     AS urgency,
  'Critical roof — no inspection requested yet' AS reason

UNION ALL

// 5d — High-score properties with zero user engagement
MATCH (pr:Property)
WHERE pr.opportunity_score >= 75
  AND NOT EXISTS {
    MATCH (:User)-[:VIEWED_OPPORTUNITY]->(pr)
  }
OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
RETURN
  'UNVIEWED_OPPORTUNITY'       AS action_type,
  pr.property_id               AS property_id,
  pr.name                      AS property_name,
  pr.city                      AS city,
  pr.opportunity_score         AS opportunity_score,
  pr.estimated_value           AS estimated_value,
  COALESCE(owner.name, 'N/A')  AS owner_name,
  COALESCE(owner.email,'N/A')  AS owner_email,
  'MEDIUM'                     AS urgency,
  'High score — no team engagement yet — assign scout' AS reason

ORDER BY urgency ASC, opportunity_score DESC
LIMIT 25;


// ============================================================
// WIDGET 6: Market Heatmap Data
// Per-market aggregates for choropleth / bar chart
// Fields: market, state, avg_score, hot_count, total_value,
//         storm_risk_score, hail_events_5yr
// ============================================================
MATCH (pr:Property)-[:LOCATED_IN]->(m:Market)
WITH m,
     COUNT(pr)                      AS total_properties,
     AVG(pr.opportunity_score)      AS avg_score,
     COUNT(CASE WHEN pr.opportunity_score >= 75 THEN 1 END) AS hot_count,
     SUM(pr.estimated_value)        AS total_value
RETURN
  m.market_id             AS market_id,
  m.name                  AS market,
  m.state                 AS state,
  m.storm_risk_score      AS storm_risk_score,
  m.hail_events_5yr       AS hail_events_5yr,
  m.vacancy_rate          AS vacancy_rate,
  m.growth_rate           AS growth_rate,
  total_properties,
  round(avg_score, 1)     AS avg_opportunity_score,
  hot_count               AS hot_properties,
  total_value
ORDER BY avg_score DESC;


// ============================================================
// WIDGET 7: Recent Activity Feed
// Last 30 days of user actions across the system
// Fields: action_type, user, property, action_date
// ============================================================
WITH date() - duration('P30D') AS cutoff
MATCH (u:User)-[act]->(pr:Property)
  WHERE TYPE(act) IN ['VIEWED_OPPORTUNITY','GENERATED_REPORT','REQUESTED_INSPECTION']
    AND act.action_date >= cutoff
OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
RETURN
  TYPE(act)            AS action_type,
  u.name               AS user_name,
  u.role               AS user_role,
  pr.property_id       AS property_id,
  pr.name              AS property_name,
  pr.city              AS city,
  pr.opportunity_score AS opportunity_score,
  COALESCE(m.name,'')  AS market,
  act.action_date      AS action_date,
  act.notes            AS notes
ORDER BY act.action_date DESC
LIMIT 50;


// ============================================================
// WIDGET 8: Proof Project ROI Summary
// Completed renovations showing demonstrated value creation
// Fields: project, asset_type, roi, value_added, market
// ============================================================
MATCH (pp:ProofProject)-[:REFERENCES]->(pr:Property)
OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
OPTIONAL MATCH (pp)-[:COMPLETED_BY]->(owner:Person)
RETURN
  pp.proof_project_id     AS project_id,
  pp.name                 AS project_name,
  pp.project_type         AS project_type,
  pp.project_value        AS project_cost,
  pp.roi                  AS roi,
  pp.value_added          AS value_added,
  pp.before_value         AS before_value,
  pp.after_value          AS after_value,
  pp.completion_date      AS completion_date,
  pp.storm_triggered      AS storm_triggered,
  pr.asset_type           AS asset_type,
  pr.city                 AS city,
  COALESCE(m.name,'')     AS market,
  owner.name              AS owner_name
ORDER BY pp.roi DESC;

// ============================================================
// Neo4j Opportunity Intelligence System
// Scoring Engine — opportunity_score per Property
//
// Formula:
//   opportunity_score =
//     0.30 * storm_signal
//   + 0.20 * damage_probability
//   + 0.15 * asset_value
//   + 0.15 * proof_proximity
//   + 0.10 * network_reachability
//   + 0.10 * engagement_signal
//
// All component scores are normalized to [0, 100].
// Final score is stored as Property.opportunity_score (0-100).
// Component scores are stored individually for auditability.
// ============================================================

// ------------------------------------------------------------
// COMPONENT 1: storm_signal  (weight 0.30)
// Signals: # storm events, max severity, hail size, recent storm
// Max raw = 40 → normalized to 0-100
// ------------------------------------------------------------
MATCH (pr:Property)
OPTIONAL MATCH (pr)-[ab:AFFECTED_BY]->(s:StormEvent)
WITH pr,
     COUNT(s)                          AS storm_count,
     COALESCE(MAX(s.severity),   0)    AS max_severity,
     COALESCE(MAX(s.hail_size),  0.0)  AS max_hail_size,
     COALESCE(MAX(
       CASE WHEN s.event_date >= date() - duration('P3Y') THEN 1 ELSE 0 END
     ), 0)                             AS recent_storm_flag

WITH pr,
     storm_count,
     max_severity,
     max_hail_size,
     recent_storm_flag,
     // Raw storm signal: count(capped 5)*2 + severity + hail(capped 3.5)*5 + recent*8
     (
       toFloat(CASE WHEN storm_count > 5 THEN 5 ELSE storm_count END) * 2.0
       + toFloat(max_severity)
       + toFloat(CASE WHEN max_hail_size > 3.5 THEN 3.5 ELSE max_hail_size END) * 5.0
       + toFloat(recent_storm_flag) * 8.0
     ) AS raw_storm

SET pr.score_storm_signal = round(100.0 * raw_storm / 40.0, 2);

// ------------------------------------------------------------
// COMPONENT 2: damage_probability  (weight 0.20)
// Signals: roof_age, roof_condition, claim pending, inspection skipped
// Max raw = 100 directly
// ------------------------------------------------------------
MATCH (pr:Property)
OPTIONAL MATCH (pr)-[ab:AFFECTED_BY]->(s:StormEvent)
WITH pr,
     pr.roof_age                                                           AS roof_age,
     CASE pr.roof_condition
       WHEN 'Critical' THEN 40
       WHEN 'Poor'     THEN 30
       WHEN 'Fair'     THEN 15
       WHEN 'Good'     THEN 5
       ELSE 0
     END                                                                    AS condition_score,
     MAX(CASE WHEN ab.claim_status = 'Pending' THEN 15 ELSE 0 END)         AS pending_claim_score,
     MAX(CASE WHEN ab.claim_filed = false       THEN 10 ELSE 0 END)         AS unfiled_claim_score,
     MAX(CASE WHEN ab.inspection_done = false   THEN 5  ELSE 0 END)         AS no_inspection_score

WITH pr,
     // Roof age contribution: capped at 40 pts (age 0-40yr maps to 0-40)
     toFloat(CASE WHEN roof_age > 40 THEN 40 ELSE roof_age END) AS age_score,
     condition_score,
     pending_claim_score,
     unfiled_claim_score,
     no_inspection_score

SET pr.score_damage_probability = round(
  toFloat(age_score) + toFloat(condition_score)
  + toFloat(pending_claim_score) + toFloat(unfiled_claim_score)
  + toFloat(no_inspection_score),
  2
);

// ------------------------------------------------------------
// COMPONENT 3: asset_value  (weight 0.15)
// Signals: estimated_value, building_sqft
// Higher value + larger = higher opportunity upside
// Score = log-normalized value score (0-100)
// ------------------------------------------------------------
MATCH (pr:Property)
WITH pr,
     // Normalize estimated_value on log scale: log10(val) mapped from [5.5,8] -> [0,100]
     CASE
       WHEN pr.estimated_value IS NULL OR pr.estimated_value <= 0 THEN 0.0
       ELSE
         100.0 * (log10(pr.estimated_value + 1.0) - 5.5) / (8.0 - 5.5)
     END AS val_score,
     // Normalize building_sqft: 0-200k sqft -> 0-30 pts
     CASE
       WHEN pr.building_sqft IS NULL THEN 0.0
       ELSE 30.0 * toFloat(CASE WHEN pr.building_sqft > 200000 THEN 200000 ELSE pr.building_sqft END) / 200000.0
     END AS sqft_score

SET pr.score_asset_value = round(
  0.7 * CASE WHEN val_score > 100 THEN 100 ELSE CASE WHEN val_score < 0 THEN 0 ELSE val_score END END
  + 0.3 * sqft_score,
  2
);

// ------------------------------------------------------------
// COMPONENT 4: proof_proximity  (weight 0.15)
// Signals: # nearby proof projects, same asset type, distance
// Max = 100 via count + type match bonus
// ------------------------------------------------------------
MATCH (pr:Property)
OPTIONAL MATCH (pp:ProofProject)-[pn:PROOF_NEAR]->(pr)
WITH pr,
     COUNT(pp)                                                        AS proof_count,
     MAX(CASE WHEN pn.same_asset_type = true THEN 20 ELSE 0 END)     AS type_match_bonus,
     MAX(CASE WHEN pn.distance_miles  < 1.0  THEN 15 ELSE 0 END)     AS close_proof_bonus

SET pr.score_proof_proximity = round(
  toFloat(CASE WHEN proof_count > 4 THEN 4 ELSE proof_count END) * 15.0
  + toFloat(type_match_bonus)
  + toFloat(close_proof_bonus),
  2
);

// ------------------------------------------------------------
// COMPONENT 5: network_reachability  (weight 0.10)
// Signals: owner trust_score, # owner connections, connector quality
// Max = 100
// ------------------------------------------------------------
MATCH (pr:Property)
OPTIONAL MATCH (owner)-[:OWNS]->(pr)
  WHERE owner:Person OR owner:Company
OPTIONAL MATCH (p:Person)-[:OWNS]->(pr)
OPTIONAL MATCH (p)-[:CONNECTED_TO]->(conn:Person)
WITH pr,
     COALESCE(MAX(p.trust_score),     50)  AS owner_trust,
     COALESCE(MAX(p.influence_score), 50)  AS owner_influence,
     COUNT(DISTINCT conn)                   AS connection_count

SET pr.score_network_reachability = round(
  toFloat(owner_trust) * 0.5
  + toFloat(owner_influence) * 0.3
  + toFloat(CASE WHEN connection_count > 10 THEN 10 ELSE connection_count END) * 2.0,
  2
);

// ------------------------------------------------------------
// COMPONENT 6: engagement_signal  (weight 0.10)
// Signals: # user views, reports generated, inspections requested
// Max raw = 30 → normalized to 0-100
// ------------------------------------------------------------
MATCH (pr:Property)
OPTIONAL MATCH (:User)-[v:VIEWED_OPPORTUNITY]->(pr)
OPTIONAL MATCH (:User)-[g:GENERATED_REPORT]->(pr)
OPTIONAL MATCH (:User)-[i:REQUESTED_INSPECTION]->(pr)
WITH pr,
     COUNT(DISTINCT v) AS view_count,
     COUNT(DISTINCT g) AS report_count,
     COUNT(DISTINCT i) AS inspection_count

WITH pr,
     (
       toFloat(CASE WHEN view_count       > 5  THEN 5  ELSE view_count       END) * 2.0
       + toFloat(CASE WHEN report_count   > 3  THEN 3  ELSE report_count     END) * 5.0
       + toFloat(CASE WHEN inspection_count> 2 THEN 2  ELSE inspection_count END) * 7.5
     ) AS raw_engagement

SET pr.score_engagement_signal = round(100.0 * raw_engagement / 30.0, 2);

// ------------------------------------------------------------
// FINAL SCORE AGGREGATION
// opportunity_score = weighted sum of all 6 components
// Stored back onto Property.opportunity_score
// ------------------------------------------------------------
MATCH (pr:Property)
SET pr.opportunity_score = round(
  0.30 * COALESCE(pr.score_storm_signal,        0.0)
  + 0.20 * COALESCE(pr.score_damage_probability, 0.0)
  + 0.15 * COALESCE(pr.score_asset_value,        0.0)
  + 0.15 * COALESCE(pr.score_proof_proximity,    0.0)
  + 0.10 * COALESCE(pr.score_network_reachability,0.0)
  + 0.10 * COALESCE(pr.score_engagement_signal,  0.0),
  2
)
RETURN pr.property_id        AS property_id,
       pr.name               AS name,
       pr.opportunity_score  AS opportunity_score,
       pr.score_storm_signal           AS storm_signal,
       pr.score_damage_probability     AS damage_probability,
       pr.score_asset_value            AS asset_value,
       pr.score_proof_proximity        AS proof_proximity,
       pr.score_network_reachability   AS network_reachability,
       pr.score_engagement_signal      AS engagement_signal
ORDER BY pr.opportunity_score DESC;

// ============================================================
// Neo4j Opportunity Intelligence System
// Relationship Import: LOAD CSV WITH HEADERS
// Run after: import_nodes.cypher
// ============================================================

// ------------------------------------------------------------
// 1. OWNS  (Person/Company)-[:OWNS]->(Property)
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/rel_owns.csv' AS row
CALL {
  WITH row
  MATCH (pr:Property { property_id: row.property_id })
  // Person owner
  FOREACH (_ IN CASE WHEN row.from_person_id <> '' THEN [1] ELSE [] END |
    MERGE (p:Person { person_id: row.from_person_id })
    MERGE (p)-[r:OWNS]->(pr)
    SET r.ownership_type  = row.ownership_type,
        r.ownership_pct   = toFloat(row.ownership_pct),
        r.acquired_date   = date(row.acquired_date),
        r.notes           = row.notes
  )
  // Company owner
  FOREACH (_ IN CASE WHEN row.from_company_id <> '' THEN [1] ELSE [] END |
    MERGE (c:Company { company_id: row.from_company_id })
    MERGE (c)-[r:OWNS]->(pr)
    SET r.ownership_type  = row.ownership_type,
        r.ownership_pct   = toFloat(row.ownership_pct),
        r.acquired_date   = date(row.acquired_date),
        r.notes           = row.notes
  )
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 2. MANAGES  Person-[:MANAGES]->(Property)
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/rel_manages.csv' AS row
CALL {
  WITH row
  MATCH (p:Person   { person_id:   row.person_id   })
  MATCH (pr:Property { property_id: row.property_id })
  MERGE (p)-[r:MANAGES]->(pr)
  SET r.management_type = row.management_type,
      r.since_date      = date(row.since_date),
      r.fee_pct         = toFloat(row.fee_pct),
      r.notes           = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 3. LOCATED_IN  Property-[:LOCATED_IN]->(Market)
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/rel_located_in.csv' AS row
CALL {
  WITH row
  MATCH (pr:Property { property_id: row.property_id })
  MATCH (m:Market    { market_id:   row.market_id   })
  MERGE (pr)-[r:LOCATED_IN]->(m)
  SET r.distance_miles = toFloat(row.distance_to_market_center_miles),
      r.submarket      = row.submarket
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 4. AFFECTED_BY  Property-[:AFFECTED_BY]->(StormEvent)
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/rel_affected_by.csv' AS row
CALL {
  WITH row
  MATCH (pr:Property  { property_id:   row.property_id })
  MATCH (s:StormEvent { storm_event_id: row.storm_id   })
  MERGE (pr)-[r:AFFECTED_BY]->(s)
  SET r.damage_severity  = row.damage_severity,
      r.damage_type      = row.damage_type,
      r.claim_filed      = (row.claim_filed = 'true'),
      r.claim_amount     = toFloat(row.claim_amount),
      r.claim_status     = row.claim_status,
      r.inspection_done  = (row.inspection_done = 'true'),
      r.notes            = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 5. CONNECTED_TO  Person-[:CONNECTED_TO]->(Person)  (bidirectional via two rels)
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/rel_connected_to.csv' AS row
CALL {
  WITH row
  MATCH (a:Person { person_id: row.person_id_a })
  MATCH (b:Person { person_id: row.person_id_b })
  MERGE (a)-[r:CONNECTED_TO]->(b)
  SET r.relationship_type = row.relationship_type,
      r.strength          = toInteger(row.strength),
      r.since_year        = toInteger(row.since_year),
      r.notes             = row.notes
  MERGE (b)-[r2:CONNECTED_TO]->(a)
  SET r2.relationship_type = row.relationship_type,
      r2.strength          = toInteger(row.strength),
      r2.since_year        = toInteger(row.since_year),
      r2.notes             = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 6. SIMILAR_TO  Property-[:SIMILAR_TO]->(Property)
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/rel_similar_to.csv' AS row
CALL {
  WITH row
  MATCH (a:Property { property_id: row.property_id_a })
  MATCH (b:Property { property_id: row.property_id_b })
  MERGE (a)-[r:SIMILAR_TO]->(b)
  SET r.similarity_score  = toFloat(row.similarity_score),
      r.similarity_basis  = row.similarity_basis,
      r.notes             = row.notes
  MERGE (b)-[r2:SIMILAR_TO]->(a)
  SET r2.similarity_score  = toFloat(row.similarity_score),
      r2.similarity_basis  = row.similarity_basis,
      r2.notes             = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 7. PROOF_NEAR  ProofProject-[:PROOF_NEAR]->(Property)
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/rel_proof_near.csv' AS row
CALL {
  WITH row
  MATCH (pp:ProofProject { proof_project_id: row.proof_project_id })
  MATCH (pr:Property     { property_id:      row.property_id      })
  MERGE (pp)-[r:PROOF_NEAR]->(pr)
  SET r.distance_miles   = toFloat(row.distance_miles),
      r.same_market      = (row.same_market = 'true'),
      r.same_asset_type  = (row.same_asset_type = 'true'),
      r.notes            = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 8. ProofProject -[:COMPLETED_BY]-> Person
//    ProofProject -[:REFERENCES]-> Property
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/proof_projects.csv' AS row
CALL {
  WITH row
  MATCH (pp:ProofProject { proof_project_id: row.proof_project_id })
  // REFERENCES -> property
  FOREACH (_ IN CASE WHEN row.property_id <> '' THEN [1] ELSE [] END |
    MERGE (pr:Property { property_id: row.property_id })
    MERGE (pp)-[:REFERENCES]->(pr)
  )
  // COMPLETED_BY -> owner
  FOREACH (_ IN CASE WHEN row.owner_person_id <> '' THEN [1] ELSE [] END |
    MERGE (p:Person { person_id: row.owner_person_id })
    MERGE (pp)-[:COMPLETED_BY]->(p)
  )
  // COMPLETED_BY -> contractor company
  FOREACH (_ IN CASE WHEN row.contractor_company_id <> '' THEN [1] ELSE [] END |
    MERGE (c:Company { company_id: row.contractor_company_id })
    MERGE (pp)-[:CONTRACTED_TO]->(c)
  )
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 9. Person -[:WORKS_FOR]-> Company
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/rel_person_company.csv' AS row
CALL {
  WITH row
  WHERE row.company_id IS NOT NULL AND row.company_id <> ''
  MATCH (p:Person  { person_id:  row.person_id  })
  MATCH (c:Company { company_id: row.company_id })
  MERGE (p)-[r:WORKS_FOR]->(c)
  SET r.title          = row.title,
      r.since_year     = toInteger(row.since_year),
      r.ownership_pct  = toFloat(row.ownership_pct),
      r.notes          = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 10. User activity: VIEWED_OPPORTUNITY, GENERATED_REPORT, REQUESTED_INSPECTION
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/rel_user_activity.csv' AS row
CALL {
  WITH row
  MATCH (u:User     { user_id:     row.user_id     })
  MATCH (pr:Property { property_id: row.property_id })
  FOREACH (_ IN CASE WHEN row.action_type = 'VIEWED_OPPORTUNITY'  THEN [1] ELSE [] END |
    MERGE (u)-[r:VIEWED_OPPORTUNITY]->(pr)
    SET r.action_date = date(row.action_date), r.notes = row.notes
  )
  FOREACH (_ IN CASE WHEN row.action_type = 'GENERATED_REPORT'    THEN [1] ELSE [] END |
    MERGE (u)-[r:GENERATED_REPORT]->(pr)
    SET r.action_date = date(row.action_date), r.notes = row.notes
  )
  FOREACH (_ IN CASE WHEN row.action_type = 'REQUESTED_INSPECTION' THEN [1] ELSE [] END |
    MERGE (u)-[r:REQUESTED_INSPECTION]->(pr)
    SET r.action_date = date(row.action_date), r.notes = row.notes
  )
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 11. Market -[:AFFECTED_BY]-> StormEvent  (market-level storm link)
// ------------------------------------------------------------
MATCH (s:StormEvent)
WITH s, split(s.affected_cities, ',') AS cities
MATCH (m:Market)
WHERE m.name IN [c IN cities | trim(c)]
MERGE (m)-[r:AFFECTED_BY]->(s)
SET r.severity = s.severity;

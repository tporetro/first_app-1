// ============================================================
// Neo4j Opportunity Intelligence System
// Node Import: LOAD CSV WITH HEADERS
// Run after: schema/constraints.cypher, schema/indexes.cypher
// ============================================================

// ------------------------------------------------------------
// 1. MARKETS  (import first — properties reference markets)
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/markets.csv' AS row
CALL {
  WITH row
  MERGE (m:Market { market_id: row.market_id })
  SET
    m.name                = row.name,
    m.state               = row.state,
    m.metro_area          = row.metro_area,
    m.avg_cap_rate        = toFloat(row.avg_cap_rate),
    m.avg_price_per_sqft  = toFloat(row.avg_price_per_sqft),
    m.vacancy_rate        = toFloat(row.vacancy_rate),
    m.growth_rate         = toFloat(row.growth_rate),
    m.population          = toInteger(row.population),
    m.median_income       = toInteger(row.median_income),
    m.storm_risk_score    = toInteger(row.storm_risk_score),
    m.hail_events_5yr     = toInteger(row.hail_events_5yr),
    m.flood_zone_pct      = toFloat(row.flood_zone_pct),
    m.notes               = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 2. PERSONS
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/persons.csv' AS row
CALL {
  WITH row
  MERGE (p:Person { person_id: row.person_id })
  SET
    p.name             = row.name,
    p.email            = row.email,
    p.phone            = row.phone,
    p.organization     = row.organization,
    p.role             = row.role,
    p.trust_score      = toInteger(row.trust_score),
    p.influence_score  = toInteger(row.influence_score),
    p.last_contact     = date(row.last_contact),
    p.city             = row.city,
    p.state            = row.state,
    p.notes            = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 3. COMPANIES
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/companies.csv' AS row
CALL {
  WITH row
  MERGE (c:Company { company_id: row.company_id })
  SET
    c.name            = row.name,
    c.type            = row.type,
    c.state           = row.state,
    c.city            = row.city,
    c.founded_year    = toInteger(row.founded_year),
    c.employee_count  = toInteger(row.employee_count),
    c.annual_revenue  = toFloat(row.annual_revenue),
    c.hq_address      = row.hq_address,
    c.website         = row.website,
    c.notes           = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 4. PROPERTIES
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/properties.csv' AS row
CALL {
  WITH row
  MERGE (pr:Property { property_id: row.property_id })
  SET
    pr.name              = row.name,
    pr.address           = row.address,
    pr.city              = row.city,
    pr.state             = row.state,
    pr.zip               = row.zip,
    pr.asset_type        = row.asset_type,
    pr.building_sqft     = toInteger(row.building_sqft),
    pr.lot_sqft          = toInteger(row.lot_sqft),
    pr.year_built        = toInteger(row.year_built),
    pr.roof_type         = row.roof_type,
    pr.roof_age          = toInteger(row.roof_age),
    pr.roof_condition    = row.roof_condition,
    pr.opportunity_score = toFloat(row.opportunity_score),
    pr.estimated_value   = toFloat(row.estimated_value),
    pr.last_sale_price   = toFloat(row.last_sale_price),
    pr.last_sale_date    = date(row.last_sale_date),
    pr.stories           = toInteger(row.stories),
    pr.parking_spaces    = toInteger(row.parking_spaces),
    pr.occupancy_rate    = toFloat(row.occupancy_rate),
    pr.noi               = toFloat(row.noi),
    pr.cap_rate          = toFloat(row.cap_rate),
    pr.notes             = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 5. STORM EVENTS
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/storm_events.csv' AS row
CALL {
  WITH row
  MERGE (s:StormEvent { storm_event_id: row.storm_id })
  SET
    s.storm_id             = row.storm_id,
    s.name                 = row.name,
    s.event_type           = row.event_type,
    s.event_date           = date(row.event_date),
    s.state                = row.state,
    s.affected_cities      = row.affected_cities,
    s.severity             = toInteger(row.severity),
    s.hail_size            = toFloat(row.hail_size),
    s.wind_speed           = toInteger(row.wind_speed),
    s.estimated_damage     = toFloat(row.estimated_damage),
    s.insurance_claims     = toInteger(row.insurance_claims),
    s.properties_affected  = toInteger(row.properties_affected),
    s.notes                = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 6. PROOF PROJECTS
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/proof_projects.csv' AS row
CALL {
  WITH row
  MERGE (pp:ProofProject { proof_project_id: row.proof_project_id })
  SET
    pp.name                = row.name,
    pp.project_type        = row.project_type,
    pp.project_value       = toFloat(row.project_value),
    pp.completion_date     = date(row.completion_date),
    pp.roi                 = toFloat(row.roi),
    pp.value_added         = toFloat(row.value_added),
    pp.before_value        = toFloat(row.before_value),
    pp.after_value         = toFloat(row.after_value),
    pp.duration_months     = toInteger(row.duration_months),
    pp.storm_triggered     = (row.storm_triggered = 'true'),
    pp.notes               = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ------------------------------------------------------------
// 7. USERS
// ------------------------------------------------------------
:auto LOAD CSV WITH HEADERS FROM 'file:///import/csv/users.csv' AS row
CALL {
  WITH row
  MERGE (u:User { user_id: row.user_id })
  SET
    u.name            = row.name,
    u.email           = row.email,
    u.role            = row.role,
    u.created_at      = date(row.created_at),
    u.last_login      = date(row.last_login),
    u.tracked_markets = row.tracked_markets,
    u.notes           = row.notes
} IN TRANSACTIONS OF 100 ROWS;

// ============================================================
// Neo4j Opportunity Intelligence System
// Schema: Performance Indexes
// ============================================================

// --- Person ---
CREATE INDEX person_name_idx IF NOT EXISTS
  FOR (p:Person) ON (p.name);

CREATE INDEX person_email_idx IF NOT EXISTS
  FOR (p:Person) ON (p.email);

CREATE INDEX person_role_idx IF NOT EXISTS
  FOR (p:Person) ON (p.role);

CREATE INDEX person_trust_score_idx IF NOT EXISTS
  FOR (p:Person) ON (p.trust_score);

// --- Company ---
CREATE INDEX company_name_idx IF NOT EXISTS
  FOR (c:Company) ON (c.name);

CREATE INDEX company_type_idx IF NOT EXISTS
  FOR (c:Company) ON (c.type);

CREATE INDEX company_state_idx IF NOT EXISTS
  FOR (c:Company) ON (c.state);

// --- Property ---
CREATE INDEX property_city_idx IF NOT EXISTS
  FOR (pr:Property) ON (pr.city);

CREATE INDEX property_state_idx IF NOT EXISTS
  FOR (pr:Property) ON (pr.state);

CREATE INDEX property_asset_type_idx IF NOT EXISTS
  FOR (pr:Property) ON (pr.asset_type);

CREATE INDEX property_opportunity_score_idx IF NOT EXISTS
  FOR (pr:Property) ON (pr.opportunity_score);

CREATE INDEX property_estimated_value_idx IF NOT EXISTS
  FOR (pr:Property) ON (pr.estimated_value);

CREATE INDEX property_roof_age_idx IF NOT EXISTS
  FOR (pr:Property) ON (pr.roof_age);

// --- Market ---
CREATE INDEX market_name_idx IF NOT EXISTS
  FOR (m:Market) ON (m.name);

CREATE INDEX market_state_idx IF NOT EXISTS
  FOR (m:Market) ON (m.state);

CREATE INDEX market_growth_rate_idx IF NOT EXISTS
  FOR (m:Market) ON (m.growth_rate);

// --- StormEvent ---
CREATE INDEX storm_event_type_idx IF NOT EXISTS
  FOR (s:StormEvent) ON (s.event_type);

CREATE INDEX storm_event_date_idx IF NOT EXISTS
  FOR (s:StormEvent) ON (s.event_date);

CREATE INDEX storm_severity_idx IF NOT EXISTS
  FOR (s:StormEvent) ON (s.severity);

CREATE INDEX storm_state_idx IF NOT EXISTS
  FOR (s:StormEvent) ON (s.state);

// --- ProofProject ---
CREATE INDEX proof_project_type_idx IF NOT EXISTS
  FOR (pp:ProofProject) ON (pp.project_type);

CREATE INDEX proof_project_roi_idx IF NOT EXISTS
  FOR (pp:ProofProject) ON (pp.roi);

// --- User ---
CREATE INDEX user_email_idx IF NOT EXISTS
  FOR (u:User) ON (u.email);

CREATE INDEX user_role_idx IF NOT EXISTS
  FOR (u:User) ON (u.role);

// --- Full-text search indexes ---
CALL db.index.fulltext.createNodeIndex(
  'property_address_fulltext',
  ['Property'],
  ['address', 'city', 'state', 'name']
) YIELD name
RETURN name;

CALL db.index.fulltext.createNodeIndex(
  'person_fulltext',
  ['Person'],
  ['name', 'email', 'organization']
) YIELD name
RETURN name;

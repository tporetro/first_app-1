// ============================================================
// Neo4j Opportunity Intelligence System
// Schema: Unique Constraints
// ============================================================

// Person
CREATE CONSTRAINT person_id_unique IF NOT EXISTS
  FOR (p:Person) REQUIRE p.person_id IS UNIQUE;

// Company
CREATE CONSTRAINT company_id_unique IF NOT EXISTS
  FOR (c:Company) REQUIRE c.company_id IS UNIQUE;

// Property
CREATE CONSTRAINT property_id_unique IF NOT EXISTS
  FOR (pr:Property) REQUIRE pr.property_id IS UNIQUE;

// Market
CREATE CONSTRAINT market_id_unique IF NOT EXISTS
  FOR (m:Market) REQUIRE m.market_id IS UNIQUE;

// StormEvent
CREATE CONSTRAINT storm_event_id_unique IF NOT EXISTS
  FOR (s:StormEvent) REQUIRE s.storm_event_id IS UNIQUE;

// ProofProject
CREATE CONSTRAINT proof_project_id_unique IF NOT EXISTS
  FOR (pp:ProofProject) REQUIRE pp.proof_project_id IS UNIQUE;

// User
CREATE CONSTRAINT user_id_unique IF NOT EXISTS
  FOR (u:User) REQUIRE u.user_id IS UNIQUE;

// ============================================================
// Opportunity Intelligence System — Schema
// Node definitions, property types, and relationship semantics
// ============================================================

// ── Node: Person ──────────────────────────────────────────────
// Represents any individual in the network:
//   owners, investors, contractors, brokers, connectors, users.
//
// Key properties:
//   person_id         STRING  UNIQUE
//   name              STRING
//   role              STRING  (owner | investor | contractor | broker |
//                              connector | adjuster | agent | user)
//   email             STRING
//   phone             STRING
//   trust_score       FLOAT   0–100  (relationship quality signal)
//   influence_score   FLOAT   0–1    (GDS PageRank write-back)
//   connector_score   FLOAT   0–∞    (GDS Betweenness write-back)
//   community_id      INTEGER         (GDS Louvain write-back)
//   engagement_tier   STRING  (HOT | WARM | ACTIVE | WATCH | COLD)

// ── Node: Property ────────────────────────────────────────────
// A commercial or residential real estate asset.
//
// Key properties:
//   property_id               STRING  UNIQUE
//   name                      STRING
//   address                   STRING
//   city                      STRING
//   state                     STRING
//   zip                       STRING
//   asset_type                STRING  (Retail | Industrial | Multifamily |
//                                      Office | Mixed-Use | Warehouse)
//   building_sqft             INTEGER
//   lot_sqft                  INTEGER
//   year_built                INTEGER
//   roof_age                  INTEGER  (years since last replacement)
//   roof_type                 STRING   (TPO | EPDM | Metal | Shingle | BUR)
//   roof_condition            STRING   (Critical | Poor | Fair | Good)
//   estimated_value           FLOAT    USD
//   opportunity_score         FLOAT    0–100  (composite)
//
// Scoring sub-scores (written by scoring_engine.cypher):
//   score_storm_signal        FLOAT 0–100
//   score_damage_probability  FLOAT 0–100
//   score_asset_value         FLOAT 0–100
//   score_proof_proximity     FLOAT 0–100
//   score_network_reachability FLOAT 0–100
//   score_engagement_signal   FLOAT 0–100
//
// GDS write-backs:
//   influence_score           FLOAT   (PageRank)
//   connector_score           FLOAT   (Betweenness)
//   community_id              INTEGER (Louvain)
//   similarity_score          FLOAT   (max SIMILAR_TO)
//   gravity_score             FLOAT   (composite: proof × centrality × cluster)

// ── Node: Market ──────────────────────────────────────────────
// A geographic market area (MSA, submarket, zip cluster).
//
// Key properties:
//   market_id          STRING  UNIQUE
//   name               STRING
//   city               STRING
//   state              STRING
//   storm_risk_score   FLOAT   0–100  (historical hail/wind frequency)
//   growth_rate        FLOAT          (annual assessment growth %)
//   avg_cap_rate       FLOAT
//   community_id       INTEGER (GDS Louvain)

// ── Node: ProofProject ────────────────────────────────────────
// A completed roofing project that serves as social proof.
// Used for proof-proximity scoring and network reachability.
//
// Key properties:
//   proof_project_id   STRING  UNIQUE
//   name               STRING
//   address            STRING
//   city               STRING
//   state              STRING
//   asset_type         STRING
//   project_type       STRING  (Re-roof | Repair | Restoration | New Install)
//   project_cost       FLOAT   USD
//   project_year       INTEGER
//   influence_score    FLOAT   (GDS PageRank)
//   community_id       INTEGER (GDS Louvain)

// ── Node: StormEvent ──────────────────────────────────────────
// A named storm or weather event affecting properties.
//
// Key properties:
//   storm_event_id     STRING  UNIQUE
//   name               STRING
//   event_date         DATE
//   storm_type         STRING  (Hail | Wind | Hurricane | Tornado | Flood)
//   hail_size_inches   FLOAT
//   wind_speed_mph     INTEGER
//   affected_zip_codes STRING[]
//   severity           STRING  (Critical | Major | Moderate | Minor)

// ── Node: Company ─────────────────────────────────────────────
// An entity that owns properties or employs Persons.
//
// Key properties:
//   company_id         STRING  UNIQUE
//   name               STRING
//   type               STRING  (LLC | Corp | REIT | Trust | Partnership)
//   state_of_formation STRING

// ── Node: User ────────────────────────────────────────────────
// A system user (sales rep, admin, analyst).
//
// Key properties:
//   user_id            STRING  UNIQUE
//   name               STRING
//   email              STRING
//   role               STRING  (admin | rep | analyst | viewer)

// ── Relationships ─────────────────────────────────────────────
// (Person|Company)-[:OWNS]->(Property)
//   ownership_type     STRING  (sole | joint | trust | llc)
//   ownership_percent  FLOAT
//   acquisition_date   DATE

// (Person)-[:CONNECTED_TO]->(Person)
//   connection_type    STRING  (family | colleague | client | referral | network)
//   strength           FLOAT   0.1–1.0  (trust/relationship strength)
//   since_year         INTEGER

// (Property)-[:LOCATED_IN]->(Market)

// (Property)-[:AFFECTED_BY]->(StormEvent)
//   claim_filed        BOOLEAN
//   claim_status       STRING  (Pending | Approved | Denied | Settled)
//   damage_severity    STRING
//   inspection_date    DATE

// (ProofProject)-[:PROOF_NEAR]->(Property)
//   distance_miles     FLOAT

// (Property)-[:SIMILAR_TO]-(Property)   [written by GDS]
//   similarity_score   FLOAT  0–1

// (Person)-[:WORKS_FOR]->(Company)
//   title              STRING
//   start_date         DATE

// (Company)-[:MANAGES]->(Property)

// (User)-[:VIEWED_OPPORTUNITY]->(Property)
//   viewed_at          DATETIME

// (User)-[:GENERATED_REPORT]->(Property)
//   generated_at       DATETIME

// (User)-[:REQUESTED_INSPECTION]->(Property)
//   requested_at       DATETIME

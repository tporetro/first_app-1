# Neo4j Opportunity Intelligence System

Commercial real estate opportunity discovery engine powered by Neo4j.

## Folder Structure

```
neo4j/
├── schema/
│   ├── constraints.cypher       # Unique constraints for all node types
│   └── indexes.cypher           # Performance + full-text indexes
├── import/
│   ├── csv/
│   │   ├── persons.csv
│   │   ├── companies.csv
│   │   ├── properties.csv       # property_id, name, address, city, state,
│   │   │                        #   asset_type, building_sqft, roof_type,
│   │   │                        #   roof_age, opportunity_score, estimated_value
│   │   ├── markets.csv          # market_id, name, state
│   │   ├── storm_events.csv     # storm_id, date, hail_size, wind_speed
│   │   ├── proof_projects.csv   # project_id, name, project_value, completion_date
│   │   ├── users.csv
│   │   ├── rel_owns.csv
│   │   ├── rel_manages.csv
│   │   ├── rel_located_in.csv
│   │   ├── rel_affected_by.csv
│   │   ├── rel_connected_to.csv
│   │   ├── rel_similar_to.csv
│   │   ├── rel_proof_near.csv
│   │   ├── rel_user_activity.csv
│   │   └── rel_person_company.csv
│   ├── import_nodes.cypher      # LOAD CSV for all 7 node types
│   └── import_relationships.cypher  # LOAD CSV for all relationship types
├── scoring/
│   └── scoring_engine.cypher    # Opportunity score formula + component scores
├── queries/
│   ├── intelligence_queries.cypher  # 15 intelligence queries
│   └── dashboard_queries.cypher     # 8 dashboard widget queries
└── scripts/
    ├── setup.sh       # Full setup: schema → nodes → rels → scoring
    ├── rescore.sh     # Re-run scoring only (no re-import)
    └── verify.sh      # Node counts, rel counts, top-5 properties
```

## Node Types

| Label | Key Properties |
|-------|---------------|
| Person | person_id, name, email, phone, organization, role, trust_score, influence_score |
| Company | company_id, name, type, state, annual_revenue |
| Property | property_id, name, address, city, state, asset_type, building_sqft, roof_type, roof_age, opportunity_score, estimated_value |
| Market | market_id, name, state, storm_risk_score, hail_events_5yr |
| StormEvent | storm_event_id, name, event_type, event_date, hail_size, wind_speed, severity |
| ProofProject | proof_project_id, name, project_type, project_value, completion_date, roi |
| User | user_id, name, email, role |

## Relationship Types

| Relationship | From → To | Key Properties |
|---|---|---|
| OWNS | Person/Company → Property | ownership_type, ownership_pct |
| MANAGES | Person → Property | management_type, fee_pct |
| LOCATED_IN | Property → Market | submarket, distance_miles |
| AFFECTED_BY | Property/Market → StormEvent | damage_severity, claim_status |
| CONNECTED_TO | Person ↔ Person | strength, relationship_type |
| SIMILAR_TO | Property ↔ Property | similarity_score, similarity_basis |
| PROOF_NEAR | ProofProject → Property | distance_miles, same_asset_type |
| WORKS_FOR | Person → Company | title, ownership_pct |
| REFERENCES | ProofProject → Property | — |
| COMPLETED_BY | ProofProject → Person | — |
| CONTRACTED_TO | ProofProject → Company | — |
| VIEWED_OPPORTUNITY | User → Property | action_date |
| GENERATED_REPORT | User → Property | action_date |
| REQUESTED_INSPECTION | User → Property | action_date |

## Opportunity Score Formula

```
opportunity_score =
    0.30 × storm_signal
  + 0.20 × damage_probability
  + 0.15 × asset_value
  + 0.15 × proof_proximity
  + 0.10 × network_reachability
  + 0.10 × engagement_signal
```

All components are normalized to [0, 100]. The composite score is stored on
`Property.opportunity_score`. Each component is also stored individually
(`score_storm_signal`, `score_damage_probability`, etc.) for audit and
explanation.

## Quick Start

```bash
# 1. Start Neo4j (Docker example)
docker run -d \
  --name neo4j-ois \
  -p 7474:7474 -p 7687:7687 \
  -e NEO4J_AUTH=neo4j/yourpassword \
  neo4j:5

# 2. Run full setup
cd neo4j/scripts
NEO4J_PASSWORD=yourpassword ./setup.sh

# 3. Verify
NEO4J_PASSWORD=yourpassword ./verify.sh

# 4. Open Neo4j Browser → http://localhost:7474
# 5. Paste and run queries from queries/intelligence_queries.cypher
```

## Intelligence Queries

| # | Query | Purpose |
|---|-------|---------|
| 01 | Top Opportunity Properties | Highest composite-scored properties |
| 02 | Highest Value Opportunities | Big-fish targets (value × score) |
| 03 | Properties Hit by Strongest Storms | Storm exposure ranking |
| 04 | Owners with Most Properties | Portfolio-level outreach targets |
| 05 | Owners Connected to Proof Projects | Warm relationship signals |
| 06 | Shortest Trust Path to Owner | Network intro routing |
| 07 | Properties Near Proof Projects | Demonstrated ROI proximity |
| 08 | Markets with Highest Opportunity Density | Geographic prioritization |
| 09 | Properties with Highest Engagement | Hottest active leads |
| 10 | Referral Partners Generating Opportunities | Channel partner ranking |
| 11 | Property Clusters with Repeated Signals | Cluster targeting |
| 12 | Storm Events Producing Most Opportunities | Storm ROI analysis |
| 13 | Top Network Connectors | Betweenness / intro quality |
| 14 | Recently Surfaced Opportunities | 30-day hot pipeline |
| 15 | Opportunity Score Breakdown | Single-property audit |

## Dashboard Widgets

| Widget | Query File | Description |
|--------|-----------|-------------|
| Top Opportunities | dashboard_queries.cypher | Ranked property table |
| Top Connectors | dashboard_queries.cypher | People who unlock deals |
| Active Clusters | dashboard_queries.cypher | Market density heat |
| Pipeline Funnel | dashboard_queries.cypher | HOT/WARM/ACTIVE/WATCH/COLD tiers |
| Best Next Actions | dashboard_queries.cypher | Pending claims, unfiled, unviewed |
| Market Heatmap | dashboard_queries.cypher | Per-market aggregates |
| Recent Activity | dashboard_queries.cypher | 30-day user action feed |
| Proof ROI Summary | dashboard_queries.cypher | Completed project returns |

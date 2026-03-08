// ============================================================
// GDS Named Graph Projection — opportunityGraph
// ============================================================
// Must be run before any other GDS algorithm.
// Creates an in-memory graph that GDS algorithms operate on.
//
// Node labels:  Person · Property · ProofProject · Market
// Relationships: OWNS · CONNECTED_TO · LOCATED_IN · SIMILAR_TO · PROOF_NEAR
//
// Relationship weight model (used by Dijkstra):
//   CONNECTED_TO  → weight 2   (default; use strength property if present)
//   PROOF_NEAR    → weight 2   (strong signal: proof adjacency)
//   OWNS          → weight 3
//   LOCATED_IN    → weight 4
//   SIMILAR_TO    → weight 4
// ============================================================

// ── Drop existing projection if it exists ─────────────────────
CALL gds.graph.exists('opportunityGraph')
YIELD exists
CALL {
  WITH exists
  WHERE exists
  CALL gds.graph.drop('opportunityGraph')
  YIELD graphName
  RETURN graphName
}
RETURN 'Projection cleared' AS status;


// ── Create projection ─────────────────────────────────────────
CALL gds.graph.project(
  'opportunityGraph',

  // ── Node projections ────────────────────────────────────────
  {
    Person: {
      properties: [
        'trust_score',
        'influence_score',
        'connector_score',
        'community_id',
        'opportunity_score'
      ]
    },
    Property: {
      properties: [
        'opportunity_score',
        'estimated_value',
        'roof_age',
        'building_sqft',
        'influence_score',
        'connector_score',
        'community_id',
        'similarity_score',
        'gravity_score'       // future: ProofProject gravity pull
      ]
    },
    ProofProject: {
      properties: [
        'influence_score',
        'community_id'
      ]
    },
    Market: {
      properties: [
        'storm_risk_score',
        'community_id'
      ]
    }
  },

  // ── Relationship projections ─────────────────────────────────
  {
    OWNS: {
      orientation: 'UNDIRECTED',
      properties: {
        weight: { defaultValue: 3.0 }
      }
    },
    CONNECTED_TO: {
      orientation: 'UNDIRECTED',
      properties: {
        // Use `strength` property if present on the relationship (0.1–1.0),
        // otherwise fall back to default weight 2.
        weight: { property: 'strength', defaultValue: 2.0 }
      }
    },
    LOCATED_IN: {
      orientation: 'UNDIRECTED',
      properties: {
        weight: { defaultValue: 4.0 }
      }
    },
    SIMILAR_TO: {
      orientation: 'UNDIRECTED',
      properties: {
        weight:           { defaultValue: 4.0 },
        similarity_score: { defaultValue: 0.0 }
      }
    },
    PROOF_NEAR: {
      orientation: 'UNDIRECTED',
      properties: {
        weight: { defaultValue: 2.0 }
      }
    }
  }
)
YIELD graphName, nodeCount, relationshipCount, projectMillis
RETURN graphName, nodeCount, relationshipCount, projectMillis;

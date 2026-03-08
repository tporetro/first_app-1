# Neo4j Graph Data Science — Opportunity Intelligence System

GDS makes the graph answer four questions that raw Cypher cannot:

| Question | Algorithm | Output |
|---|---|---|
| Who connects clusters? | Betweenness Centrality | `connector_score` |
| Who has network influence? | PageRank | `influence_score` |
| Which hidden clusters exist? | Louvain Community Detection | `community_id` |
| What is similar to this? | Node Similarity (Jaccard) | `SIMILAR_TO` + `similarity_score` |
| What is the best path? | Weighted Dijkstra | `path_cost`, `path_nodes` |

---

## File Structure

```
neo4j/gds/
├── gds_projection.cypher   # Step 1 — create opportunityGraph projection
├── gds_centrality.cypher   # Stream betweenness + pagerank (explore)
├── gds_communities.cypher  # Stream louvain community detection (explore)
├── gds_similarity.cypher   # Stream + write SIMILAR_TO relationships
├── gds_paths.cypher        # Dijkstra + Yen's k-shortest path queries
├── gds_writeback.cypher    # Write all scores back to Neo4j node properties
├── gds_queries.cypher      # Dashboard queries (use after writeback)
└── README_GDS.md           # This file
```

---

## Run Order

```bash
# 1. Create the in-memory graph projection
cypher-shell -f gds_projection.cypher

# 2. (Optional) Explore algorithm output before writing
cypher-shell -f gds_centrality.cypher
cypher-shell -f gds_communities.cypher
cypher-shell -f gds_similarity.cypher

# 3. Write all scores back to Neo4j
cypher-shell -f gds_writeback.cypher

# 4. Run dashboard queries
cypher-shell -f gds_queries.cypher

# 5. Find paths (requires projection to still be loaded)
cypher-shell -f gds_paths.cypher
```

Or using the Node.js API server:

```bash
curl -X POST http://localhost:3001/api/gds/write
```

---

## Node Properties Written

### Person
| Property | Algorithm | Description |
|---|---|---|
| `connector_score` | Betweenness Centrality | Bridge score — how often this person sits between others |
| `influence_score` | PageRank | Network importance — flows from important nodes |
| `community_id` | Louvain | Cluster membership ID |

### Property
| Property | Algorithm | Description |
|---|---|---|
| `community_id` | Louvain | Cluster membership ID |
| `similarity_score` | Node Similarity | Max Jaccard similarity to any other property |
| `influence_score` | PageRank | Network importance of property node |
| `gravity_score` | Composite | Network pull score (see formula below) |

### ProofProject
| Property | Algorithm | Description |
|---|---|---|
| `influence_score` | PageRank | Network centrality of proof node |
| `community_id` | Louvain | Cluster membership |

### Relationships
| Relationship | Property | Description |
|---|---|---|
| `SIMILAR_TO` | `similarity_score` | Jaccard similarity (0.0–1.0) between properties |

---

## Named Graph Projection

**Graph name:** `opportunityGraph`

**Node labels:** Person · Property · ProofProject · Market

**Relationship types and weights:**

| Relationship | Weight | Notes |
|---|---|---|
| `CONNECTED_TO` | 2 (or `strength` property) | Strongest social connection |
| `PROOF_NEAR` | 2 | Proof-node adjacency |
| `OWNS` | 3 | Ownership link |
| `LOCATED_IN` | 4 | Geographic/market link |
| `SIMILAR_TO` | 4 | Structural similarity |

Lower weight = stronger path. Dijkstra finds the lowest total cost path.

---

## gravity_score Formula

The `gravity_score` is a composite property that measures the total
"network pull" a property exerts — combining proof proximity, centrality,
similarity, cluster density, and engagement signal.

```
gravity_score =
  0.30 × proof_influence      (nearest ProofProject.influence_score)
  0.25 × network_centrality   (Property.connector_score, normalized /1000)
  0.20 × similarity_pull      (max SIMILAR_TO.similarity_score)
  0.15 × cluster_density      (community property count, normalized /20)
  0.10 × activation_pull      (score_engagement_signal / 100)
```

This score feeds into:
- Opportunity ranking
- Dossier generation
- Ad audience selection

---

## Example Queries

### Top connectors
```cypher
MATCH (p:Person)
WHERE p.connector_score IS NOT NULL
RETURN p.name, p.role, p.connector_score, p.influence_score
ORDER BY p.connector_score DESC LIMIT 25
```

### Best path from connector to owner
```cypher
CALL gds.shortestPath.dijkstra.stream('opportunityGraph', {
  sourceNode: id(sourceNode),
  targetNode: id(targetNode),
  relationshipWeightProperty: 'weight'
})
YIELD totalCost, nodeIds, path
RETURN [nId IN nodeIds | gds.util.asNode(nId).name] AS path_nodes,
       round(totalCost, 2) AS path_cost
```

### Similar properties
```cypher
MATCH (source:Property {name: 'Warespaces Lewisville'})
MATCH (source)-[sim:SIMILAR_TO]-(similar:Property)
RETURN similar.name, sim.similarity_score
ORDER BY sim.similarity_score DESC LIMIT 10
```

### Community opportunity density
```cypher
MATCH (pr:Property)
WHERE pr.community_id IS NOT NULL
WITH pr.community_id AS community_id, COUNT(pr) AS property_count,
     AVG(pr.opportunity_score) AS avg_score, SUM(pr.estimated_value) AS total_value
RETURN community_id, property_count, round(avg_score, 1), total_value
ORDER BY avg_score DESC LIMIT 10
```

---

## Requirements

- Neo4j 5.x
- Neo4j Graph Data Science plugin >= 2.6
- Memory: allocate at least `dbms.memory.heap.max_size=2G` for GDS operations

Install GDS: https://neo4j.com/docs/graph-data-science/current/installation/

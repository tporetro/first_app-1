# Business Leader Network

A graph-powered B2B sales and marketing intelligence application built with Ruby on Rails and Neo4j — inspired by [Kantwert's presentation at GraphConnect](https://neo4j.com/blog/cypher-and-gql/the-power-of-business-leader-networks/).

## What it does

Maps professional relationships between business leaders so sales and marketing teams can:

- **Find introduction paths** — shortest connection chain to any target leader ("6 degrees" warm intro)
- **Identify top connectors** — bridge nodes that unlock the largest portions of the network
- **Target by industry** — all reachable leaders in FinTech, HealthTech, CleanTech, etc.
- **Explore company networks** — employees, board members, and alumni for any company
- **Analyse mutual connections** — shared contacts between any two leaders

## Graph Schema

```
(:BusinessLeader {id, name, title, email, linkedin_url, bio, influence_score})
  -[:WORKS_AT      {since, current}]->          (:Company)
  -[:KNOWS         {since, source, strength}]->  (:BusinessLeader)
  -[:BOARD_MEMBER_OF {since}]->                  (:Company)
  -[:PREVIOUSLY_WORKED_AT {from, to, title}]->   (:Company)

(:Company {id, name, industry, size, hq_city, website, description})
(:Industry {name})
```

## Key Cypher Queries

**Shortest introduction path**
```cypher
MATCH path = shortestPath(
  (source:BusinessLeader {id: $source_id})-[:KNOWS*..6]-(target:BusinessLeader {id: $target_id})
)
RETURN nodes(path)
```

**Extended network within N hops**
```cypher
MATCH (source:BusinessLeader {id: $id})-[:KNOWS*1..$hops]-(reachable:BusinessLeader)
WHERE source <> reachable
RETURN DISTINCT reachable ORDER BY reachable.influence_score DESC
```

**Top connectors (bridge nodes)**
```cypher
MATCH (l:BusinessLeader)-[:KNOWS]-(other)
WITH l, count(DISTINCT other) AS degree
RETURN l.name, degree ORDER BY degree DESC
```

**B2B industry targeting**
```cypher
MATCH (l:BusinessLeader)-[:WORKS_AT {current: true}]->(c:Company {industry: $industry})
OPTIONAL MATCH (l)-[:KNOWS]-(other)
WITH l, c, count(DISTINCT other) AS connections
RETURN l.name, c.name, connections ORDER BY connections DESC
```

**Mutual connections**
```cypher
MATCH (a:BusinessLeader {id: $id})-[:KNOWS]-(mutual)-[:KNOWS]-(b:BusinessLeader {id: $other_id})
WHERE a <> b AND mutual <> a AND mutual <> b
RETURN DISTINCT mutual
```

## Setup

### 1. Install & start Neo4j

Download Neo4j Community Edition from https://neo4j.com/download/
Default credentials: `neo4j` / `password` (change via Neo4j Browser on first login)

### 2. Configure environment

```bash
export NEO4J_URL=http://localhost:7474
export NEO4J_USERNAME=neo4j
export NEO4J_PASSWORD=your_password
```

### 3. Install Ruby dependencies

```bash
bundle install
```

### 4. Seed the graph

```bash
rake db:seed
```

This loads 20 business leaders across 8 companies (FinTech, Data & AI, Cybersecurity, HealthTech, Real Estate, SaaS/ERP, CleanTech, Media), 38 KNOWS relationships, 7 board seats, and 7 work-history entries.

### 5. Start the server

```bash
rails server
```

Open http://localhost:3000

## Rake Tasks

```bash
rake neo4j:status          # Check connection and print graph stats
rake neo4j:top_connectors  # Print top-connected leaders to stdout
rake neo4j:reset           # Clear all graph data (prompts for confirmation)
rake CYPHER='...' neo4j:query  # Run a raw Cypher query
```

## Architecture

| File | Purpose |
|------|---------|
| `lib/neo4j/client.rb` | Raw HTTP client for Neo4j's transactional Cypher endpoint |
| `config/initializers/neo4j.rb` | Boot-time connection + schema/index creation |
| `app/models/business_leader.rb` | Graph ORM for `:BusinessLeader` nodes + path queries |
| `app/models/company.rb` | Graph ORM for `:Company` nodes |
| `app/controllers/business_leaders_controller.rb` | Profile, network, path, mutual views |
| `app/controllers/companies_controller.rb` | Company directory and detail |
| `app/controllers/network_controller.rb` | Dashboard, top connectors, industry targeting |
| `db/seeds.rb` | Sample graph with 20 leaders, 8 companies, 38 connections |
| `lib/tasks/neo4j.rake` | Operational rake tasks |

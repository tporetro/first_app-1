# Neo4j Owner Network

A business intelligence platform for commercial real estate professionals. Upload CSV files of building owners, automatically map their network connections (friends, family, work history, followers, social profiles) into Neo4j, and explore the data as an interactive visual graph with built-in analysis tools.

## Features

- **CSV Upload** – drag-and-drop import of owner data with flexible column mapping
- **Visual Graph** – interactive network visualization powered by vis-network with physics simulation, zoom, pan, filtering by node/relationship type, and click-to-inspect
- **Shortest Path Analysis** – find the fastest connection route between any two people in the network
- **Influence Network Analysis** – rank owners by degree centrality to identify the most connected (highest-value) targets
- **Community Detection** – automatically group owners into clusters based on relationship density
- **Screenshot Export** – one-click PNG export of the graph

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Database | Neo4j (graph DB) |
| Backend | Node.js + Express |
| Graph visualization | vis-network 9.x |
| File upload | multer + csv-parse |
| Frontend | Vanilla JS + custom CSS |

## Node & Relationship Schema

**Node types:**
- `Person` – owners and their contacts (blue circles)
- `Building` – commercial properties (orange squares)
- `Company` – employers / companies (green diamonds)

**Relationship types:**
- `OWNS` – person owns a building
- `WORKS_AT` – employment (past or present)
- `KNOWS` – general connection / acquaintance
- `FAMILY_OF` – family relationship (with optional `relation` property)
- `FOLLOWS` – social media follow

## Setup

### Prerequisites

- Node.js 18+
- A running Neo4j instance (Community or AuraDB free tier)

### 1. Install dependencies

```bash
npm install
```

### 2. Configure environment

```bash
cp .env.example .env
```

Edit `.env`:

```
NEO4J_URI=bolt://localhost:7687
NEO4J_USER=neo4j
NEO4J_PASSWORD=your_password
PORT=3000
```

For **Neo4j AuraDB** (cloud), use the `neo4j+s://` URI from your AuraDB console.

### 3. Start the server

```bash
npm start
# or for development with auto-reload:
npm run dev
```

Open [http://localhost:3000](http://localhost:3000)

## CSV Format

All columns except `owner_name` are optional. Multi-value fields use **semicolons** as separators within a single cell.

| Column | Format |
|--------|--------|
| `owner_name` | Full name (**required**) |
| `email` | Email address |
| `linkedin` | linkedin.com/in/handle |
| `twitter` | @handle |
| `instagram` | @handle |
| `facebook` | Profile URL |
| `phone` | Phone number |
| `building_address` | Full address |
| `building_name` | Building display name |
| `building_type` | office / retail / industrial / mixed |
| `connections` | `Name;Name;Name` |
| `family` | `Name:relation;Name:relation` |
| `work_history` | `Company:Role:Years;Company:Role:Years` |
| `followers` | `Name;Name` (people who follow this owner) |
| `employer` | Current employer (shorthand) |

Download the included [`sample_owners.csv`](http://localhost:3000/sample_owners.csv) to see a complete example with 8 Chicago commercial building owners.

## Pages

| URL | Description |
|-----|-------------|
| `/` | Dashboard – stats and top influencers |
| `/graph` | Full interactive graph view |
| `/upload` | CSV upload and import |
| `/analysis` | Shortest path, influence ranking, community detection |

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/stats` | Node and relationship counts |
| GET | `/api/graph` | Full graph data (JSON) |
| GET | `/api/people` | All person names (for dropdowns) |
| POST | `/api/upload` | Upload and import CSV |
| GET | `/api/analysis/shortest-path?from=X&to=Y` | Shortest path between two people |
| GET | `/api/analysis/influence?limit=N` | Influence rankings |
| GET | `/api/analysis/communities` | Community detection |
| DELETE | `/api/data` | Clear all graph data |

## Graph Filters

On the Graph page you can filter by:
- **Node types** – toggle People, Buildings, Companies on/off
- **Relationship types** – toggle OWNS, WORKS_AT, KNOWS, FAMILY_OF, FOLLOWS

## Deploying to Production

The app works on any Node.js host (Railway, Render, Heroku, etc.). Set the three Neo4j environment variables and the `PORT`. Use **Neo4j AuraDB** for a managed cloud database.

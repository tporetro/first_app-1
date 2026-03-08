import 'dotenv/config';
import express from 'express';
import cors from 'cors';
import neo4j from 'neo4j-driver';
import { fileURLToPath } from 'url';
import path from 'path';

const app = express();
app.use(cors());
app.use(express.json());

// ── Neo4j driver ────────────────────────────────────────────
const driver = neo4j.driver(
  process.env.NEO4J_URI      || 'bolt://localhost:7687',
  neo4j.auth.basic(
    process.env.NEO4J_USER     || 'neo4j',
    process.env.NEO4J_PASSWORD || 'neo4j'
  )
);
const DB = process.env.NEO4J_DB || 'neo4j';

// ── Helpers ─────────────────────────────────────────────────
function toPlain(value) {
  if (value === null || value === undefined) return value;
  if (neo4j.isInt(value))  return value.toNumber();
  if (neo4j.isDate(value) || neo4j.isDateTime(value) ||
      neo4j.isLocalDateTime(value)) return value.toString();
  if (Array.isArray(value)) return value.map(toPlain);
  if (typeof value === 'object' && value.year) return value.toString(); // neo4j date fallback
  return value;
}

function nodeToObj(n) {
  const props = Object.fromEntries(
    Object.entries(n.properties).map(([k, v]) => [k, toPlain(v)])
  );
  const type = n.labels[0] ?? 'Unknown';
  const name =
    props.name              ||
    props.address           ||
    props.property_id       ||
    props.market_id         ||
    props.storm_event_id    ||
    props.proof_project_id  ||
    props.user_id           ||
    props.company_id        ||
    props.person_id         ||
    `Node(${n.identity})`;
  return { id: n.identity.toString(), type, labels: n.labels, name, ...props };
}

function relToObj(r, sourceId, targetId) {
  const props = Object.fromEntries(
    Object.entries(r.properties).map(([k, v]) => [k, toPlain(v)])
  );
  return {
    id:     r.identity.toString(),
    source: sourceId.toString(),
    target: targetId.toString(),
    type:   r.type,
    ...props,
  };
}

function run(cypher, params = {}) {
  const session = driver.session({ database: DB });
  return session.run(cypher, params).finally(() => session.close());
}

// ── /api/graph ───────────────────────────────────────────────
// Full graph: Person, Property, Market, ProofProject, StormEvent
// Relationships: OWNS, CONNECTED_TO, LOCATED_IN, AFFECTED_BY, PROOF_NEAR
app.get('/api/graph', async (req, res) => {
  const limit  = Math.min(parseInt(req.query.limit  ?? '300'), 600);
  const labels = req.query.labels?.split(',').filter(Boolean) ?? [];

  const labelFilter = labels.length
    ? `WHERE any(l IN labels(n) WHERE l IN $labels)
          OR any(l IN labels(m) WHERE l IN $labels)`
    : '';

  try {
    const result = await run(`
      MATCH (n)-[r]->(m)
      WHERE type(r) IN ['OWNS','CONNECTED_TO','LOCATED_IN','AFFECTED_BY','PROOF_NEAR',
                        'WORKS_FOR','MANAGES','SIMILAR_TO','REFERENCES','COMPLETED_BY']
        AND any(l IN labels(n) WHERE l IN ['Person','Property','Market',
                                           'ProofProject','StormEvent','Company','User'])
        AND any(l IN labels(m) WHERE l IN ['Person','Property','Market',
                                           'ProofProject','StormEvent','Company','User'])
        ${labelFilter ? 'AND (' + labelFilter.replace('WHERE','') + ')' : ''}
      RETURN n, r, m
      LIMIT $limit
    `, { limit: neo4j.int(limit), labels });

    const nodesMap = new Map();
    const links    = [];

    for (const rec of result.records) {
      const n  = rec.get('n');
      const m  = rec.get('m');
      const r  = rec.get('r');
      const nId = n.identity.toString();
      const mId = m.identity.toString();
      if (!nodesMap.has(nId)) nodesMap.set(nId, nodeToObj(n));
      if (!nodesMap.has(mId)) nodesMap.set(mId, nodeToObj(m));
      links.push(relToObj(r, nId, mId));
    }

    res.json({ nodes: [...nodesMap.values()], links });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── /api/graph/node/:id — neighborhood expansion ─────────────
app.get('/api/graph/node/:id', async (req, res) => {
  try {
    const nodeId = neo4j.int(parseInt(req.params.id));

    const result = await run(`
      MATCH (n) WHERE id(n) = $nodeId
      OPTIONAL MATCH (n)-[r]-(neighbor)
      WHERE any(l IN labels(neighbor) WHERE l IN ['Person','Property','Market',
                                                   'ProofProject','StormEvent','Company','User'])
      RETURN n,
             collect({
               relId:    id(r),
               relType:  type(r),
               props:    properties(r),
               neighbor: neighbor,
               nbrId:    id(neighbor),
               dir: CASE WHEN startNode(r) = n THEN 'out' ELSE 'in' END
             }) AS connections
    `, { nodeId });

    if (!result.records.length) return res.status(404).json({ error: 'Not found' });

    const rec  = result.records[0];
    const node = nodeToObj(rec.get('n'));
    const connections = rec.get('connections')
      .filter(c => c.neighbor !== null)
      .map(c => ({
        direction: c.dir,
        relType:   c.relType,
        relId:     toPlain(c.relId),
        relProps:  Object.fromEntries(Object.entries(c.props).map(([k,v]) => [k, toPlain(v)])),
        neighbor:  nodeToObj(c.neighbor),
      }));

    // Build sub-graph for expansion
    const nodesMap = new Map([[node.id, node]]);
    const links    = [];
    for (const c of connections) {
      nodesMap.set(c.neighbor.id, c.neighbor);
      if (c.direction === 'out') {
        links.push({ id: String(c.relId), source: node.id, target: c.neighbor.id, type: c.relType });
      } else {
        links.push({ id: String(c.relId), source: c.neighbor.id, target: node.id, type: c.relType });
      }
    }

    res.json({ node, connections, subgraph: { nodes: [...nodesMap.values()], links } });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── /api/graph/path — shortest path between two nodes ────────
app.get('/api/graph/path', async (req, res) => {
  const { from, to } = req.query;
  if (!from || !to) return res.status(400).json({ error: 'from and to required' });

  try {
    const result = await run(`
      MATCH (a), (b)
      WHERE id(a) = $from AND id(b) = $to
      MATCH path = shortestPath((a)-[*1..6]-(b))
      RETURN [n IN nodes(path)     | { node: n, id: id(n) }]          AS pathNodes,
             [r IN relationships(path) | {
               rel:    r,
               source: id(startNode(r)),
               target: id(endNode(r))
             }] AS pathRels
    `, { from: neo4j.int(parseInt(from)), to: neo4j.int(parseInt(to)) });

    if (!result.records.length) return res.json({ found: false, nodes: [], links: [] });

    const rec      = result.records[0];
    const nodes    = rec.get('pathNodes').map(x => nodeToObj(x.node));
    const links    = rec.get('pathRels').map(x => relToObj(x.rel, x.source, x.target));

    res.json({ found: true, nodes, links });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── /api/graph/search ────────────────────────────────────────
app.get('/api/graph/search', async (req, res) => {
  const q = (req.query.q ?? '').trim();
  if (!q) return res.json({ nodes: [] });

  try {
    const result = await run(`
      MATCH (n)
      WHERE any(l IN labels(n) WHERE l IN ['Person','Property','Market',
                                           'ProofProject','StormEvent','Company','User'])
        AND (toLower(n.name)    CONTAINS toLower($q)
          OR toLower(n.address) CONTAINS toLower($q)
          OR toLower(n.email)   CONTAINS toLower($q)
          OR n.person_id        = $q
          OR n.property_id      = $q
          OR n.market_id        = $q)
      RETURN n
      LIMIT 20
    `, { q });

    res.json({ nodes: result.records.map(r => nodeToObj(r.get('n'))) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── /api/opportunities ───────────────────────────────────────
app.get('/api/opportunities', async (req, res) => {
  try {
    const result = await run(`
      MATCH (pr:Property)
      OPTIONAL MATCH (pr)-[:LOCATED_IN]->(m:Market)
      OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
      OPTIONAL MATCH (co:Company)-[:OWNS]->(pr)
      RETURN
        pr.property_id              AS id,
        pr.name                     AS property,
        pr.address                  AS address,
        pr.city                     AS city,
        pr.state                    AS state,
        COALESCE(m.name,'—')        AS market,
        pr.asset_type               AS asset_type,
        pr.building_sqft            AS building_sqft,
        pr.roof_age                 AS roof_age,
        pr.roof_condition           AS roof_condition,
        pr.opportunity_score        AS opportunity_score,
        pr.estimated_value          AS estimated_value,
        COALESCE(owner.name, co.name, '—') AS owner,
        COALESCE(owner.email,'')    AS owner_email,
        COALESCE(owner.phone,'')    AS owner_phone,
        pr.score_storm_signal       AS score_storm,
        pr.score_damage_probability AS score_damage,
        pr.score_asset_value        AS score_value,
        pr.score_proof_proximity    AS score_proof,
        pr.score_network_reachability AS score_network,
        pr.score_engagement_signal  AS score_engagement
      ORDER BY pr.opportunity_score DESC
      LIMIT 20
    `);

    res.json(result.records.map(r => Object.fromEntries(
      r.keys.map(k => [k, toPlain(r.get(k))])
    )));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── /api/connectors ──────────────────────────────────────────
app.get('/api/connectors', async (req, res) => {
  try {
    const result = await run(`
      MATCH (connector:Person)-[:CONNECTED_TO]->(owner:Person)-[:OWNS]->(pr:Property)
      WHERE pr.opportunity_score >= 55
      WITH connector,
           COUNT(DISTINCT owner)       AS owners_reachable,
           COUNT(DISTINCT pr)          AS reachable_properties,
           SUM(pr.estimated_value)     AS pipeline_value,
           AVG(pr.opportunity_score)   AS avg_score
      OPTIONAL MATCH (connector)-[:CONNECTED_TO]->(peer:Person)
      WITH connector, owners_reachable, reachable_properties, pipeline_value, avg_score,
           COUNT(DISTINCT peer) AS connection_count
      RETURN
        connector.person_id       AS id,
        connector.name            AS name,
        connector.role            AS role,
        connector.email           AS email,
        connector.trust_score     AS trust_score,
        connector.influence_score AS influence_score,
        connection_count,
        owners_reachable,
        reachable_properties,
        pipeline_value,
        round(avg_score, 1)       AS avg_opportunity_score
      ORDER BY reachable_properties DESC, pipeline_value DESC
      LIMIT 10
    `);

    res.json(result.records.map(r => Object.fromEntries(
      r.keys.map(k => [k, toPlain(r.get(k))])
    )));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── /api/clusters ────────────────────────────────────────────
app.get('/api/clusters', async (req, res) => {
  try {
    const result = await run(`
      MATCH (pr:Property)-[:LOCATED_IN]->(m:Market)
      MATCH (pr)-[:AFFECTED_BY]->(s:StormEvent)
      WHERE pr.opportunity_score >= 60
      WITH m, pr.asset_type AS asset_type,
           COUNT(DISTINCT pr)             AS property_count,
           AVG(pr.opportunity_score)      AS avg_score,
           SUM(pr.estimated_value)        AS total_value,
           COUNT(DISTINCT s)              AS storm_event_count,
           COLLECT(DISTINCT pr.name)[..4] AS sample_properties
      WHERE property_count >= 2
      RETURN
        m.market_id         AS market_id,
        m.name              AS market,
        m.state             AS state,
        m.storm_risk_score  AS market_storm_risk,
        asset_type,
        property_count,
        round(avg_score, 1) AS avg_opportunity_score,
        total_value,
        storm_event_count,
        sample_properties
      ORDER BY avg_score DESC, property_count DESC
    `);

    res.json(result.records.map(r => Object.fromEntries(
      r.keys.map(k => [k, toPlain(r.get(k))])
    )));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── /api/pipeline ────────────────────────────────────────────
app.get('/api/pipeline', async (req, res) => {
  try {
    const result = await run(`
      MATCH (pr:Property)
      WITH pr,
        CASE
          WHEN pr.opportunity_score >= 85 THEN 'HOT'
          WHEN pr.opportunity_score >= 70 THEN 'WARM'
          WHEN pr.opportunity_score >= 55 THEN 'ACTIVE'
          WHEN pr.opportunity_score >= 40 THEN 'WATCH'
          ELSE 'COLD'
        END AS tier,
        CASE
          WHEN pr.opportunity_score >= 85 THEN 1
          WHEN pr.opportunity_score >= 70 THEN 2
          WHEN pr.opportunity_score >= 55 THEN 3
          WHEN pr.opportunity_score >= 40 THEN 4
          ELSE 5
        END AS tier_order
      WITH tier, tier_order,
           COUNT(pr)                 AS property_count,
           SUM(pr.estimated_value)   AS total_value,
           AVG(pr.opportunity_score) AS avg_score,
           MAX(pr.opportunity_score) AS max_score
      RETURN tier, property_count, total_value, round(avg_score,1) AS avg_score, max_score
      ORDER BY tier_order ASC
    `);

    // Also return funnel metrics
    const [views, reports, inspections] = await Promise.all([
      run(`MATCH ()-[r:VIEWED_OPPORTUNITY]->() RETURN COUNT(r) AS c`),
      run(`MATCH ()-[r:GENERATED_REPORT]->()   RETURN COUNT(r) AS c`),
      run(`MATCH ()-[r:REQUESTED_INSPECTION]->() RETURN COUNT(r) AS c`),
    ]);

    const viewCount = toPlain(views.records[0].get('c'));
    const rptCount  = toPlain(reports.records[0].get('c'));
    const insCount  = toPlain(inspections.records[0].get('c'));

    res.json({
      tiers: result.records.map(r => Object.fromEntries(
        r.keys.map(k => [k, toPlain(r.get(k))])
      )),
      funnel: {
        teaser_views:         viewCount,
        reports_generated:    rptCount,
        inspections_requested: insCount,
        activation_rate: rptCount > 0
          ? Math.round((insCount / rptCount) * 100) / 100
          : 0,
      },
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── /api/actions ─────────────────────────────────────────────
app.get('/api/actions', async (req, res) => {
  try {
    const result = await run(`
      // Pending claims
      MATCH (pr:Property)-[ab:AFFECTED_BY]->(s:StormEvent)
      WHERE ab.claim_status = 'Pending' AND pr.opportunity_score >= 60
      OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
      RETURN 'inspect property'        AS action,
             pr.name                   AS target_node,
             pr.property_id            AS property_id,
             pr.opportunity_score      AS opportunity_score,
             pr.estimated_value        AS estimated_value,
             COALESCE(owner.name,'—')  AS owner_name,
             COALESCE(owner.email,'')  AS owner_email,
             'Storm claim pending — inspection window open' AS reason,
             'HIGH' AS urgency

      UNION ALL

      MATCH (pr:Property)-[ab:AFFECTED_BY]->(s:StormEvent)
      WHERE ab.claim_filed = false AND pr.opportunity_score >= 65
      OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
      RETURN 'send opportunity report'  AS action,
             pr.name                    AS target_node,
             pr.property_id             AS property_id,
             pr.opportunity_score       AS opportunity_score,
             pr.estimated_value         AS estimated_value,
             COALESCE(owner.name,'—')   AS owner_name,
             COALESCE(owner.email,'')   AS owner_email,
             'Storm damage unfiled — proactive outreach window' AS reason,
             'HIGH' AS urgency

      UNION ALL

      MATCH (pr:Property)
      WHERE pr.roof_condition = 'Critical' AND pr.opportunity_score >= 70
        AND NOT EXISTS { MATCH (:User)-[:REQUESTED_INSPECTION]->(pr) }
      OPTIONAL MATCH (owner:Person)-[:OWNS]->(pr)
      RETURN 'inspect property'         AS action,
             pr.name                    AS target_node,
             pr.property_id             AS property_id,
             pr.opportunity_score       AS opportunity_score,
             pr.estimated_value         AS estimated_value,
             COALESCE(owner.name,'—')   AS owner_name,
             COALESCE(owner.email,'')   AS owner_email,
             'Critical roof — no inspection scheduled' AS reason,
             'MEDIUM' AS urgency

      UNION ALL

      MATCH (connector:Person)-[:CONNECTED_TO]->(owner:Person)-[:OWNS]->(pr:Property)
      WHERE pr.opportunity_score >= 75
        AND NOT EXISTS { MATCH (:User)-[:VIEWED_OPPORTUNITY]->(pr) }
      WITH connector, pr, owner
      ORDER BY pr.opportunity_score DESC
      LIMIT 5
      RETURN 'contact connector'        AS action,
             connector.name             AS target_node,
             pr.property_id             AS property_id,
             pr.opportunity_score       AS opportunity_score,
             pr.estimated_value         AS estimated_value,
             owner.name                 AS owner_name,
             owner.email                AS owner_email,
             'High-score unviewed property — connector can intro to owner' AS reason,
             'MEDIUM' AS urgency

      ORDER BY urgency ASC, opportunity_score DESC
      LIMIT 25
    `);

    res.json(result.records.map(r => Object.fromEntries(
      r.keys.map(k => [k, toPlain(r.get(k))])
    )));
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ── /api/stats ───────────────────────────────────────────────
app.get('/api/stats', async (req, res) => {
  try {
    const [nodeRes, relRes] = await Promise.all([
      run(`MATCH (n) WHERE any(l IN labels(n) WHERE l IN
            ['Person','Property','Market','ProofProject','StormEvent','Company','User'])
           RETURN labels(n)[0] AS label, COUNT(n) AS count ORDER BY count DESC`),
      run(`MATCH ()-[r]->() WHERE type(r) IN
            ['OWNS','CONNECTED_TO','LOCATED_IN','AFFECTED_BY','PROOF_NEAR',
             'WORKS_FOR','MANAGES','SIMILAR_TO','REFERENCES','COMPLETED_BY']
           RETURN type(r) AS type, COUNT(r) AS count ORDER BY count DESC`),
    ]);
    res.json({
      nodes: nodeRes.records.map(r => ({ label: r.get('label'), count: toPlain(r.get('count')) })),
      relationships: relRes.records.map(r => ({ type: r.get('type'), count: toPlain(r.get('count')) })),
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// ══════════════════════════════════════════════════════════════
// GDS — Graph Data Science algorithms
// Each endpoint tries native GDS first; falls back to Cypher
// approximation so the dashboard works even without the GDS plugin.
// ══════════════════════════════════════════════════════════════

function gdsErr(err) {
  // Detect missing GDS plugin
  return err.code === 'Neo.ClientError.Procedure.ProcedureNotFound'
      || err.message?.toLowerCase().includes('gds.')
      || err.message?.toLowerCase().includes('no procedure');
}

// ── 1. Betweenness Centrality ────────────────────────────────
// "Who actually connects clusters?"
// Finds bridge people: brokers, connectors, community figures.
// High score = sits on many shortest paths between others.
app.get('/api/gds/betweenness', async (req, res) => {
  // GDS path first
  try {
    const r = await run(`
      CALL gds.betweenness.stream({
        nodeProjection: ['Person','Company'],
        relationshipProjection: {
          CONNECTED_TO: { orientation: 'UNDIRECTED' },
          WORKS_FOR:    { orientation: 'UNDIRECTED' }
        }
      })
      YIELD nodeId, score
      WITH gds.util.asNode(nodeId) AS n, score
      WHERE score > 0
      RETURN
        toString(id(n))   AS id,
        n.name            AS name,
        labels(n)[0]      AS type,
        n.role            AS role,
        n.email           AS email,
        n.trust_score     AS trust_score,
        n.influence_score AS influence_score,
        round(score, 2)   AS betweenness_score,
        false             AS approximated
      ORDER BY score DESC
      LIMIT 20
    `);
    return res.json({
      algorithm: 'betweenness_centrality',
      source: 'gds',
      rows: r.records.map(rec => Object.fromEntries(rec.keys.map(k => [k, toPlain(rec.get(k))]))),
    });
  } catch (err) {
    if (!gdsErr(err)) return res.status(500).json({ error: err.message });
  }

  // Cypher fallback: degree centrality on CONNECTED_TO graph
  try {
    const r = await run(`
      MATCH (p:Person)
      OPTIONAL MATCH (p)-[:CONNECTED_TO]-(peer:Person)
      WITH p, COUNT(DISTINCT peer) AS degree
      OPTIONAL MATCH (p)-[:OWNS]->(pr:Property)
      RETURN
        toString(id(p))   AS id,
        p.name            AS name,
        'Person'          AS type,
        p.role            AS role,
        p.email           AS email,
        p.trust_score     AS trust_score,
        p.influence_score AS influence_score,
        toFloat(degree)   AS betweenness_score,
        true              AS approximated
      ORDER BY degree DESC
      LIMIT 20
    `);
    res.json({
      algorithm: 'betweenness_centrality',
      source: 'cypher_degree_approx',
      rows: r.records.map(rec => Object.fromEntries(rec.keys.map(k => [k, toPlain(rec.get(k))]))),
    });
  } catch (inner) {
    res.status(500).json({ error: inner.message });
  }
});

// ── 2. PageRank ──────────────────────────────────────────────
// "Who has the most network influence?"
// Not just direct connections — importance flows from important nodes.
// Ranks: owners, connectors, proof nodes, companies.
app.get('/api/gds/pagerank', async (req, res) => {
  try {
    const r = await run(`
      CALL gds.pageRank.stream({
        nodeProjection: ['Person','Property','Company','ProofProject'],
        relationshipProjection: {
          OWNS:         { orientation: 'NATURAL' },
          CONNECTED_TO: { orientation: 'NATURAL' },
          WORKS_FOR:    { orientation: 'NATURAL' },
          MANAGES:      { orientation: 'NATURAL' },
          PROOF_NEAR:   { orientation: 'NATURAL' }
        },
        dampingFactor: 0.85,
        maxIterations: 20
      })
      YIELD nodeId, score
      WITH gds.util.asNode(nodeId) AS n, score
      RETURN
        toString(id(n))   AS id,
        n.name            AS name,
        labels(n)[0]      AS type,
        n.role            AS role,
        n.asset_type      AS asset_type,
        n.opportunity_score AS opportunity_score,
        round(score, 5)   AS pagerank_score,
        false             AS approximated
      ORDER BY score DESC
      LIMIT 30
    `);
    return res.json({
      algorithm: 'pagerank',
      source: 'gds',
      rows: r.records.map(rec => Object.fromEntries(rec.keys.map(k => [k, toPlain(rec.get(k))]))),
    });
  } catch (err) {
    if (!gdsErr(err)) return res.status(500).json({ error: err.message });
  }

  // Fallback: weighted in-degree (incoming relationship count)
  try {
    const r = await run(`
      MATCH (n) WHERE any(l IN labels(n) WHERE l IN ['Person','Property','Company','ProofProject'])
      OPTIONAL MATCH ()-[r_in]->(n)
      OPTIONAL MATCH (n)-[r_out]->()
      WITH n,
           COUNT(DISTINCT r_in)  AS in_degree,
           COUNT(DISTINCT r_out) AS out_degree
      RETURN
        toString(id(n))   AS id,
        n.name            AS name,
        labels(n)[0]      AS type,
        n.role            AS role,
        n.asset_type      AS asset_type,
        n.opportunity_score AS opportunity_score,
        toFloat(in_degree + out_degree * 0.5) AS pagerank_score,
        true              AS approximated
      ORDER BY pagerank_score DESC
      LIMIT 30
    `);
    res.json({
      algorithm: 'pagerank',
      source: 'cypher_degree_approx',
      rows: r.records.map(rec => Object.fromEntries(rec.keys.map(k => [k, toPlain(rec.get(k))]))),
    });
  } catch (inner) {
    res.status(500).json({ error: inner.message });
  }
});

// ── 3. Louvain Community Detection ──────────────────────────
// "Which hidden ecosystems exist in the graph?"
// Lewisville retail cluster · Plano retail · broker-centered networks
// Surfaces groups of nodes that are densely connected to each other.
app.get('/api/gds/communities', async (req, res) => {
  try {
    const r = await run(`
      CALL gds.louvain.stream({
        nodeProjection: ['Person','Property','Company','Market'],
        relationshipProjection: {
          CONNECTED_TO: { orientation: 'UNDIRECTED' },
          OWNS:         { orientation: 'UNDIRECTED' },
          WORKS_FOR:    { orientation: 'UNDIRECTED' },
          LOCATED_IN:   { orientation: 'UNDIRECTED' }
        }
      })
      YIELD nodeId, communityId
      WITH communityId, collect(gds.util.asNode(nodeId)) AS members
      WITH communityId,
           size(members)                                              AS size,
           [n IN members | n.name][..6]                              AS sample_names,
           [n IN members | toString(id(n))]                          AS node_ids,
           SIZE([n IN members WHERE labels(n)[0]='Person'])   AS person_count,
           SIZE([n IN members WHERE labels(n)[0]='Property'])  AS property_count,
           SIZE([n IN members WHERE labels(n)[0]='Market'])    AS market_count,
           SIZE([n IN members WHERE labels(n)[0]='Company'])   AS company_count,
           // Dominant asset type if all properties
           [n IN members WHERE n.asset_type IS NOT NULL | n.asset_type][0] AS hint_asset_type,
           // Dominant market
           [n IN members WHERE labels(n)[0]='Market' | n.name][0] AS hint_market,
           // Average opportunity score across properties in community
           AVG([n IN members WHERE n.opportunity_score IS NOT NULL | n.opportunity_score][0]) AS avg_opp_score
      WHERE size >= 2
      RETURN
        communityId,
        size,
        sample_names,
        node_ids[..12]      AS node_ids,
        person_count,
        property_count,
        market_count,
        company_count,
        hint_asset_type,
        hint_market,
        round(COALESCE(avg_opp_score, 0), 1) AS avg_opp_score,
        false AS approximated
      ORDER BY size DESC
      LIMIT 20
    `);
    return res.json({
      algorithm: 'louvain_community_detection',
      source: 'gds',
      communities: r.records.map(rec => Object.fromEntries(rec.keys.map(k => [k, toPlain(rec.get(k))]))),
    });
  } catch (err) {
    if (!gdsErr(err)) return res.status(500).json({ error: err.message });
  }

  // Fallback: weakly connected components via Cypher BFS
  try {
    const r = await run(`
      MATCH (n)-[r]-(m)
      WHERE any(l IN labels(n) WHERE l IN ['Person','Property','Company','Market'])
        AND any(l IN labels(m) WHERE l IN ['Person','Property','Company','Market'])
      WITH n.person_id AS group_seed,
           collect(DISTINCT n.name)[..6] AS sample_names,
           COUNT(DISTINCT n)             AS size,
           COUNT(DISTINCT CASE WHEN labels(n)[0]='Person'   THEN n END) AS person_count,
           COUNT(DISTINCT CASE WHEN labels(n)[0]='Property' THEN n END) AS property_count,
           COUNT(DISTINCT CASE WHEN labels(n)[0]='Market'   THEN n END) AS market_count
      WHERE group_seed IS NOT NULL AND size >= 2
      RETURN
        group_seed                  AS communityId,
        size,
        sample_names,
        []                          AS node_ids,
        person_count,
        property_count,
        market_count,
        0                           AS company_count,
        null                        AS hint_asset_type,
        null                        AS hint_market,
        0.0                         AS avg_opp_score,
        true                        AS approximated
      ORDER BY size DESC
      LIMIT 20
    `);
    res.json({
      algorithm: 'louvain_community_detection',
      source: 'cypher_approx',
      communities: r.records.map(rec => Object.fromEntries(rec.keys.map(k => [k, toPlain(rec.get(k))]))),
    });
  } catch (inner) {
    res.status(500).json({ error: inner.message });
  }
});

// ── 4. Node Similarity ───────────────────────────────────────
// "Show me more like this."
// Jaccard similarity on shared neighbors.
// owners mode:     owners who own similar property portfolios
// properties mode: properties with similar market/storm exposure
app.get('/api/gds/similarity', async (req, res) => {
  const mode = req.query.mode === 'properties' ? 'properties' : 'owners';

  const gdsConfig = mode === 'owners'
    ? {
        nodeProjection: { Person: {}, Property: {} },
        relProjection:  { OWNS: { orientation: 'NATURAL' } },
        filterSrc:      'Person',
        filterTgt:      'Person',
      }
    : {
        nodeProjection: { Property: {}, Market: {} },
        relProjection:  { LOCATED_IN: { orientation: 'NATURAL' } },
        filterSrc:      'Property',
        filterTgt:      'Property',
      };

  try {
    const r = await run(`
      CALL gds.nodeSimilarity.stream({
        nodeProjection:         $nodeProjection,
        relationshipProjection: $relProjection,
        similarityCutoff:       0.2,
        topK:                   5
      })
      YIELD node1, node2, similarity
      WITH gds.util.asNode(node1) AS a, gds.util.asNode(node2) AS b, similarity
      WHERE labels(a)[0] = $src AND labels(b)[0] = $tgt
      RETURN
        toString(id(a))         AS id1,
        a.name                  AS name1,
        labels(a)[0]            AS type1,
        a.role                  AS role1,
        a.asset_type            AS asset_type1,
        a.opportunity_score     AS score1,
        toString(id(b))         AS id2,
        b.name                  AS name2,
        labels(b)[0]            AS type2,
        b.role                  AS role2,
        b.asset_type            AS asset_type2,
        b.opportunity_score     AS score2,
        round(similarity, 3)    AS similarity
      ORDER BY similarity DESC
      LIMIT 25
    `, {
      nodeProjection: gdsConfig.nodeProjection,
      relProjection:  gdsConfig.relProjection,
      src:            gdsConfig.filterSrc,
      tgt:            gdsConfig.filterTgt,
    });
    return res.json({
      algorithm: 'node_similarity',
      source: 'gds',
      mode,
      pairs: r.records.map(rec => Object.fromEntries(rec.keys.map(k => [k, toPlain(rec.get(k))]))),
    });
  } catch (err) {
    if (!gdsErr(err)) return res.status(500).json({ error: err.message });
  }

  // Fallback: overlap via shared properties/markets using Cypher
  try {
    let cypher;
    if (mode === 'owners') {
      cypher = `
        MATCH (a:Person)-[:OWNS]->(p:Property)<-[:OWNS]-(b:Person)
        WHERE id(a) < id(b)
        WITH a, b, COUNT(DISTINCT p) AS shared,
             SIZE((a)-[:OWNS]->()) AS sizeA,
             SIZE((b)-[:OWNS]->()) AS sizeB
        WITH a, b, shared,
             toFloat(shared) / (sizeA + sizeB - shared) AS similarity
        WHERE similarity > 0
        RETURN
          toString(id(a)) AS id1, a.name AS name1, 'Person' AS type1, a.role AS role1,
          null AS asset_type1, null AS score1,
          toString(id(b)) AS id2, b.name AS name2, 'Person' AS type2, b.role AS role2,
          null AS asset_type2, null AS score2,
          round(similarity, 3) AS similarity
        ORDER BY similarity DESC
        LIMIT 25
      `;
    } else {
      cypher = `
        MATCH (a:Property)-[:LOCATED_IN]->(m:Market)<-[:LOCATED_IN]-(b:Property)
        WHERE id(a) < id(b) AND a.asset_type = b.asset_type
        WITH a, b, COUNT(DISTINCT m) AS shared
        RETURN
          toString(id(a)) AS id1, a.name AS name1, 'Property' AS type1, null AS role1,
          a.asset_type AS asset_type1, a.opportunity_score AS score1,
          toString(id(b)) AS id2, b.name AS name2, 'Property' AS type2, null AS role2,
          b.asset_type AS asset_type2, b.opportunity_score AS score2,
          toFloat(shared) AS similarity
        ORDER BY similarity DESC
        LIMIT 25
      `;
    }
    const r = await run(cypher);
    res.json({
      algorithm: 'node_similarity',
      source: 'cypher_overlap_approx',
      mode,
      pairs: r.records.map(rec => Object.fromEntries(rec.keys.map(k => [k, toPlain(rec.get(k))]))),
    });
  } catch (inner) {
    res.status(500).json({ error: inner.message });
  }
});

// ── 5. Weighted Dijkstra ─────────────────────────────────────
// "What is the lowest-resistance path between two nodes?"
// Not hop count — relationship STRENGTH as edge weight:
//   family  → cost 0.1 (very strong)  |  trusted client → 0.3
//   owns    → 0.4                      |  proof adjacency → 0.5
//   market  → 0.7                      |  default → 0.8
// Lower total cost = warmer introduction path.
app.get('/api/gds/paths', async (req, res) => {
  const { from, to } = req.query;
  if (!from || !to) return res.status(400).json({ error: 'from and to required' });
  const fromId = neo4j.int(parseInt(from));
  const toId   = neo4j.int(parseInt(to));

  // Try GDS Dijkstra (requires weight property on relationships)
  try {
    const r = await run(`
      CALL gds.shortestPath.dijkstra.stream({
        nodeProjection: ['Person','Company','Property','ProofProject'],
        relationshipProjection: {
          CONNECTED_TO: {
            orientation: 'UNDIRECTED',
            properties: { cost: { property: 'strength', defaultValue: 0.5 } }
          },
          OWNS: {
            orientation: 'UNDIRECTED',
            properties: { cost: { defaultValue: 0.4 } }
          },
          WORKS_FOR: {
            orientation: 'UNDIRECTED',
            properties: { cost: { defaultValue: 0.3 } }
          },
          PROOF_NEAR: {
            orientation: 'UNDIRECTED',
            properties: { cost: { defaultValue: 0.5 } }
          }
        },
        sourceNode: $from,
        targetNode: $to,
        relationshipWeightProperty: 'cost'
      })
      YIELD totalCost, nodeIds, costs
      RETURN totalCost,
             [nId IN nodeIds | gds.util.asNode(nId)] AS pathNodes,
             costs
    `, { from: fromId, to: toId });

    if (!r.records.length) return res.json({ found: false });

    const rec = r.records[0];
    return res.json({
      found:      true,
      source:     'gds_dijkstra',
      totalCost:  toPlain(rec.get('totalCost')),
      pathNodes:  rec.get('pathNodes').map(nodeToObj),
      costs:      rec.get('costs').map(toPlain),
    });
  } catch (err) {
    if (!gdsErr(err) && !err.message?.includes('no path')) {
      return res.status(500).json({ error: err.message });
    }
  }

  // Fallback: Cypher shortestPath with cost reduction via REDUCE
  try {
    const r = await run(`
      MATCH (a), (b) WHERE id(a) = $from AND id(b) = $to
      MATCH path = shortestPath((a)-[*1..8]-(b))
      WITH path,
           reduce(cost = 0.0, r IN relationships(path) |
             cost + CASE type(r)
               WHEN 'CONNECTED_TO' THEN toFloat(COALESCE(r.strength, 0.5))
               WHEN 'WORKS_FOR'    THEN 0.3
               WHEN 'OWNS'         THEN 0.4
               WHEN 'PROOF_NEAR'   THEN 0.5
               WHEN 'LOCATED_IN'   THEN 0.7
               ELSE 0.8
             END
           ) AS totalCost
      RETURN
        [n IN nodes(path)          | n]       AS pathNodes,
        [r IN relationships(path)  | type(r)] AS relTypes,
        totalCost
      ORDER BY totalCost ASC
      LIMIT 3
    `, { from: fromId, to: toId });

    if (!r.records.length) return res.json({ found: false });

    const paths = r.records.map(rec => ({
      totalCost: toPlain(rec.get('totalCost')),
      pathNodes: rec.get('pathNodes').map(nodeToObj),
      relTypes:  rec.get('relTypes'),
    }));

    res.json({
      found:    true,
      source:   'cypher_shortestpath',
      ...paths[0],
      alternates: paths.slice(1),
    });
  } catch (inner) {
    res.status(500).json({ error: inner.message });
  }
});

// ── GDS Write-back: persist scores to node properties ────────
// POST /api/gds/write
// Runs GDS algorithms in write mode and stores results as node properties:
//   connector_score   (betweenness)
//   influence_score   (pagerank)
//   community_id      (louvain)
// These properties can then be used in scoring queries and dashboards.
app.post('/api/gds/write', async (req, res) => {
  const results = {};
  const errors  = {};

  // Write betweenness → Person.connector_score
  try {
    const r = await run(`
      CALL gds.betweenness.write({
        nodeProjection: ['Person','Company'],
        relationshipProjection: {
          CONNECTED_TO: { orientation: 'UNDIRECTED' },
          WORKS_FOR:    { orientation: 'UNDIRECTED' }
        },
        writeProperty: 'connector_score'
      })
      YIELD nodePropertiesWritten, computeMillis
      RETURN nodePropertiesWritten, computeMillis
    `);
    const rec = r.records[0];
    results.betweenness = {
      property: 'connector_score',
      nodesWritten: toPlain(rec.get('nodePropertiesWritten')),
      ms: toPlain(rec.get('computeMillis')),
    };
  } catch (err) {
    errors.betweenness = gdsErr(err) ? 'GDS not available' : err.message;
    // Fallback: write degree centrality as connector_score
    try {
      await run(`
        MATCH (p:Person)
        WITH p, SIZE([(p)-[:CONNECTED_TO]-() | 1]) AS degree
        SET p.connector_score = toFloat(degree)
      `);
      results.betweenness = { property: 'connector_score', source: 'degree_fallback' };
    } catch (_) {}
  }

  // Write pagerank → *.influence_score
  try {
    const r = await run(`
      CALL gds.pageRank.write({
        nodeProjection: ['Person','Property','Company','ProofProject'],
        relationshipProjection: {
          OWNS: { orientation: 'NATURAL' }, CONNECTED_TO: { orientation: 'NATURAL' },
          WORKS_FOR: { orientation: 'NATURAL' }, MANAGES: { orientation: 'NATURAL' },
          PROOF_NEAR: { orientation: 'NATURAL' }
        },
        dampingFactor: 0.85, maxIterations: 20,
        writeProperty: 'gds_pagerank'
      })
      YIELD nodePropertiesWritten, computeMillis
      RETURN nodePropertiesWritten, computeMillis
    `);
    const rec = r.records[0];
    results.pagerank = {
      property: 'gds_pagerank',
      nodesWritten: toPlain(rec.get('nodePropertiesWritten')),
      ms: toPlain(rec.get('computeMillis')),
    };
  } catch (err) {
    errors.pagerank = gdsErr(err) ? 'GDS not available' : err.message;
  }

  // Write louvain → *.community_id
  try {
    const r = await run(`
      CALL gds.louvain.write({
        nodeProjection: ['Person','Property','Company','Market'],
        relationshipProjection: {
          CONNECTED_TO: { orientation: 'UNDIRECTED' }, OWNS: { orientation: 'UNDIRECTED' },
          WORKS_FOR:    { orientation: 'UNDIRECTED' }, LOCATED_IN: { orientation: 'UNDIRECTED' }
        },
        writeProperty: 'community_id'
      })
      YIELD nodePropertiesWritten, computeMillis, communityCount
      RETURN nodePropertiesWritten, computeMillis, communityCount
    `);
    const rec = r.records[0];
    results.louvain = {
      property: 'community_id',
      nodesWritten: toPlain(rec.get('nodePropertiesWritten')),
      communities: toPlain(rec.get('communityCount')),
      ms: toPlain(rec.get('computeMillis')),
    };
  } catch (err) {
    errors.louvain = gdsErr(err) ? 'GDS not available' : err.message;
  }

  const hasGds = Object.keys(errors).length === 0 || Object.values(errors).some(e => !String(e).includes('GDS not available'));
  res.json({ ok: true, gds_available: hasGds, written: results, errors });
});

// ── Static (production build) ────────────────────────────────
const __filename = fileURLToPath(import.meta.url);
const __dir      = path.dirname(__filename);
if (process.env.NODE_ENV === 'production') {
  app.use(express.static(path.join(__dir, '../client/dist')));
  app.get(/^(?!\/api).*/, (_req, res) => {
    res.sendFile(path.join(__dir, '../client/dist/index.html'));
  });
}

// ── Start ────────────────────────────────────────────────────
const PORT = process.env.PORT || 3001;
app.listen(PORT, () => {
  console.log(`Graph API → http://localhost:${PORT}`);
  console.log(`Neo4j    → ${process.env.NEO4J_URI || 'bolt://localhost:7687'}`);
});

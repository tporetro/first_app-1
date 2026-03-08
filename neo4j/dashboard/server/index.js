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

const { getSession } = require('./neo4j');

// ---------------------------------------------------------------------------
// Helpers – v2 HTTP API returns plain JSON objects for nodes/relationships
// ---------------------------------------------------------------------------

function nodeToObj(n) {
  return {
    id:    n.elementId,
    label: n.properties.name || n.properties.address || n.elementId,
    type:  (n.labels && n.labels[0]) || 'Unknown',
    props: n.properties || {},
  };
}

function relToObj(r) {
  return {
    id:   r.elementId,
    from: r.startNodeElementId,
    to:   r.endNodeElementId,
    type: r.type,
    props: r.properties || {},
  };
}

// v2 path is a flat array alternating [node, rel, node, rel, ..., node]
function pathNodes(path) {
  return path.filter((_, i) => i % 2 === 0);
}
function pathRels(path) {
  return path.filter((_, i) => i % 2 === 1);
}

function formatGraph(records) {
  const nodes = new Map();
  const edges = new Map();

  for (const rec of records) {
    const n = rec.get('n');
    const r = rec.get('r');
    const m = rec.get('m');

    if (n && n.elementId) {
      if (!nodes.has(n.elementId)) nodes.set(n.elementId, nodeToObj(n));
    }
    if (m && m.elementId) {
      if (!nodes.has(m.elementId)) nodes.set(m.elementId, nodeToObj(m));
    }
    if (r && r.elementId) {
      if (!edges.has(r.elementId)) edges.set(r.elementId, relToObj(r));
    }
  }

  return {
    nodes: Array.from(nodes.values()),
    edges: Array.from(edges.values()),
  };
}

// ---------------------------------------------------------------------------
// Full graph
// ---------------------------------------------------------------------------

async function getFullGraph(options = {}) {
  const session = getSession();
  try {
    const labelFilter = buildLabelFilter(options.nodeTypes);
    const relFilter   = buildRelFilter(options.relTypes);
    const limit       = Number(options.limit) || 1000;

    const result = await session.run(
      `MATCH (n)
       ${labelFilter ? 'WHERE ' + labelFilter : ''}
       OPTIONAL MATCH (n)-[r]->(m)
       ${relFilter   ? 'WHERE ' + relFilter   : ''}
       RETURN n, r, m
       LIMIT $limit`,
      { limit }
    );
    return formatGraph(result.records);
  } finally {
    await session.close();
  }
}

// ---------------------------------------------------------------------------
// Shortest path
// ---------------------------------------------------------------------------

async function findShortestPath(fromName, toName) {
  const session = getSession();
  try {
    const result = await session.run(
      `MATCH (a:Person {name: $from}), (b:Person {name: $to})
       MATCH p = shortestPath((a)-[*..15]-(b))
       RETURN p, length(p) AS pathLength
       LIMIT 1`,
      { from: fromName, to: toName }
    );

    if (!result.records.length) {
      return { found: false, message: 'No path found between these nodes.' };
    }

    const rec    = result.records[0];
    const path   = rec.get('p');   // flat array [node, rel, node, …]
    const length = rec.get('pathLength');

    const nodes = pathNodes(path).map(nodeToObj);
    const edges = pathRels(path).map(relToObj);

    return { found: true, pathLength: length, nodes, edges };
  } finally {
    await session.close();
  }
}

// ---------------------------------------------------------------------------
// Influence / degree centrality
// ---------------------------------------------------------------------------

async function getInfluenceScores(limit = 50) {
  const session = getSession();
  try {
    const result = await session.run(
      `MATCH (n:Person)
       OPTIONAL MATCH (n)-[r]-()
       WITH n, count(r) AS degree
       ORDER BY degree DESC
       LIMIT $limit
       RETURN n.name AS name, n.email AS email, n.linkedin AS linkedin, degree`,
      { limit }
    );
    return result.records.map(r => ({
      id:             r.get('name'),
      name:           r.get('name'),
      email:          r.get('email')    || '',
      linkedin:       r.get('linkedin') || '',
      degree:         Number(r.get('degree')),
      influenceScore: Number(r.get('degree')),
    }));
  } finally {
    await session.close();
  }
}

// ---------------------------------------------------------------------------
// Community detection (JS BFS on returned adjacency list)
// ---------------------------------------------------------------------------

async function getCommunities() {
  const session = getSession();
  try {
    const result = await session.run(
      `MATCH (n:Person)
       OPTIONAL MATCH (n)-[]-(m:Person)
       RETURN n.name AS nName, m.name AS mName`
    );

    const adj   = new Map();
    const names = new Set();

    for (const rec of result.records) {
      const nName = rec.get('nName');
      const mName = rec.get('mName');

      names.add(nName);
      if (!adj.has(nName)) adj.set(nName, new Set());

      if (mName && mName !== nName) {
        names.add(mName);
        if (!adj.has(mName)) adj.set(mName, new Set());
        adj.get(nName).add(mName);
        adj.get(mName).add(nName);
      }
    }

    // Ensure all isolated nodes are included
    for (const name of names) {
      if (!adj.has(name)) adj.set(name, new Set());
    }

    // BFS connected components
    const community = new Map();
    let cid = 0;
    for (const nodeId of adj.keys()) {
      if (community.has(nodeId)) continue;
      const queue = [nodeId];
      while (queue.length) {
        const cur = queue.shift();
        if (community.has(cur)) continue;
        community.set(cur, cid);
        for (const nb of (adj.get(cur) || [])) {
          if (!community.has(nb)) queue.push(nb);
        }
      }
      cid++;
    }

    const communities = new Map();
    for (const [nodeId, id] of community.entries()) {
      if (!communities.has(id)) communities.set(id, []);
      communities.get(id).push({ id: nodeId, name: nodeId });
    }

    return Array.from(communities.entries())
      .map(([id, members]) => ({ communityId: id, size: members.length, members }))
      .sort((a, b) => b.size - a.size);
  } finally {
    await session.close();
  }
}

// ---------------------------------------------------------------------------
// Dashboard stats
// ---------------------------------------------------------------------------

async function getNetworkStats() {
  const session = getSession();
  try {
    const [nodes, rels, persons, buildings, companies] = await Promise.all([
      session.run('MATCH (n)          RETURN count(n)  AS c'),
      session.run('MATCH ()-[r]->()   RETURN count(r)  AS c'),
      session.run('MATCH (n:Person)   RETURN count(n)  AS c'),
      session.run('MATCH (n:Building) RETURN count(n)  AS c'),
      session.run('MATCH (n:Company)  RETURN count(n)  AS c'),
    ]);
    return {
      totalNodes:         Number(nodes.records[0].get('c')),
      totalRelationships: Number(rels.records[0].get('c')),
      persons:            Number(persons.records[0].get('c')),
      buildings:          Number(buildings.records[0].get('c')),
      companies:          Number(companies.records[0].get('c')),
    };
  } finally {
    await session.close();
  }
}

// ---------------------------------------------------------------------------
// Person names for dropdowns
// ---------------------------------------------------------------------------

async function getAllPersonNames() {
  const session = getSession();
  try {
    const result = await session.run(
      'MATCH (p:Person) RETURN p.name AS name ORDER BY p.name'
    );
    return result.records.map(r => r.get('name')).filter(Boolean);
  } finally {
    await session.close();
  }
}

// ---------------------------------------------------------------------------
// Filter builders
// ---------------------------------------------------------------------------

function buildLabelFilter(types) {
  if (!types || !types.length) return '';
  return types.map(t => `n:${t}`).join(' OR ');
}

function buildRelFilter(types) {
  if (!types || !types.length) return '';
  return `type(r) IN [${types.map(t => `'${t}'`).join(', ')}]`;
}

module.exports = {
  getFullGraph,
  findShortestPath,
  getInfluenceScores,
  getCommunities,
  getNetworkStats,
  getAllPersonNames,
};

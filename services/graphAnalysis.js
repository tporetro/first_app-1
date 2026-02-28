const { getSession } = require('./neo4j');

// ---------------------------------------------------------------------------
// Graph data retrieval
// ---------------------------------------------------------------------------

async function getFullGraph(options = {}) {
  const session = getSession();
  try {
    const labelFilter = buildLabelFilter(options.nodeTypes);
    const relFilter   = buildRelFilter(options.relTypes);

    const result = await session.run(
      `MATCH (n)
       ${labelFilter ? 'WHERE ' + labelFilter : ''}
       OPTIONAL MATCH (n)-[r]->(m)
       ${relFilter   ? 'WHERE ' + relFilter   : ''}
       RETURN n, r, m
       LIMIT $limit`,
      { limit: Number(options.limit) || 1000 }
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

    const record  = result.records[0];
    const path    = record.get('p');
    const length  = record.get('pathLength');

    const allNodes = path.segments.map(s => s.start).concat([path.end]);
    const allRels  = path.segments.map(s => s.relationship);

    return {
      found: true,
      pathLength: length,
      nodes: allNodes.map(nodeToObj),
      edges: allRels.map(relToObj),
    };
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
       RETURN id(n) AS nodeId, n.name AS name, n.email AS email,
              n.linkedin AS linkedin, degree`,
      { limit }
    );
    return result.records.map(r => ({
      id:             String(r.get('nodeId')),
      name:           r.get('name'),
      email:          r.get('email') || '',
      linkedin:       r.get('linkedin') || '',
      degree:         Number(r.get('degree')),
      influenceScore: Number(r.get('degree')),
    }));
  } finally {
    await session.close();
  }
}

// ---------------------------------------------------------------------------
// Community detection (connected components via JS BFS on returned graph)
// ---------------------------------------------------------------------------

async function getCommunities() {
  const session = getSession();
  try {
    const result = await session.run(
      `MATCH (n:Person)
       OPTIONAL MATCH (n)-[r]-(m:Person)
       RETURN id(n) AS nId, n.name AS nName,
              id(m) AS mId, m.name AS mName`
    );

    // Build adjacency list
    const adj  = new Map();
    const names = new Map();
    for (const rec of result.records) {
      const nId   = String(rec.get('nId'));
      const nName = rec.get('nName');
      names.set(nId, nName);
      if (!adj.has(nId)) adj.set(nId, new Set());

      const mId = rec.get('mId') !== null ? String(rec.get('mId')) : null;
      if (mId) {
        const mName = rec.get('mName');
        names.set(mId, mName);
        if (!adj.has(mId)) adj.set(mId, new Set());
        adj.get(nId).add(mId);
        adj.get(mId).add(nId);
      }
    }

    // BFS to assign community IDs
    const community = new Map();
    let communityId = 0;
    for (const nodeId of adj.keys()) {
      if (community.has(nodeId)) continue;
      const queue = [nodeId];
      while (queue.length) {
        const cur = queue.shift();
        if (community.has(cur)) continue;
        community.set(cur, communityId);
        for (const neighbor of (adj.get(cur) || [])) {
          if (!community.has(neighbor)) queue.push(neighbor);
        }
      }
      communityId++;
    }

    // Summarise
    const communities = new Map();
    for (const [nodeId, cid] of community.entries()) {
      if (!communities.has(cid)) communities.set(cid, []);
      communities.get(cid).push({ id: nodeId, name: names.get(nodeId) });
    }

    return Array.from(communities.entries()).map(([cid, members]) => ({
      communityId: cid,
      size: members.length,
      members,
    })).sort((a, b) => b.size - a.size);
  } finally {
    await session.close();
  }
}

// ---------------------------------------------------------------------------
// Dashboard statistics
// ---------------------------------------------------------------------------

async function getNetworkStats() {
  const session = getSession();
  try {
    const [nodes, rels, persons, buildings, companies] = await Promise.all([
      session.run('MATCH (n)             RETURN count(n)  AS c'),
      session.run('MATCH ()-[r]->()      RETURN count(r)  AS c'),
      session.run('MATCH (n:Person)      RETURN count(n)  AS c'),
      session.run('MATCH (n:Building)    RETURN count(n)  AS c'),
      session.run('MATCH (n:Company)     RETURN count(n)  AS c'),
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
// All person names (for dropdowns)
// ---------------------------------------------------------------------------

async function getAllPersonNames() {
  const session = getSession();
  try {
    const result = await session.run(
      'MATCH (p:Person) RETURN p.name AS name ORDER BY p.name'
    );
    return result.records.map(r => r.get('name'));
  } finally {
    await session.close();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function buildLabelFilter(types) {
  if (!types || !types.length) return '';
  return types.map(t => `n:${t}`).join(' OR ');
}

function buildRelFilter(types) {
  if (!types || !types.length) return '';
  return `type(r) IN [${types.map(t => `'${t}'`).join(', ')}]`;
}

function nodeToObj(n) {
  return {
    id:    String(n.identity),
    label: n.properties.name || n.properties.address || String(n.identity),
    type:  n.labels[0] || 'Unknown',
    props: n.properties,
  };
}

function relToObj(r) {
  return {
    id:   String(r.identity),
    from: String(r.start),
    to:   String(r.end),
    type: r.type,
    props: r.properties,
  };
}

function formatGraph(records) {
  const nodes = new Map();
  const edges = new Map();

  for (const rec of records) {
    const n = rec.get('n');
    const r = rec.get('r');
    const m = rec.get('m');

    if (n) {
      const id = String(n.identity);
      if (!nodes.has(id)) nodes.set(id, nodeToObj(n));
    }
    if (m) {
      const id = String(m.identity);
      if (!nodes.has(id)) nodes.set(id, nodeToObj(m));
    }
    if (r) {
      const id = String(r.identity);
      if (!edges.has(id)) edges.set(id, relToObj(r));
    }
  }

  return {
    nodes: Array.from(nodes.values()),
    edges: Array.from(edges.values()),
  };
}

module.exports = {
  getFullGraph,
  findShortestPath,
  getInfluenceScores,
  getCommunities,
  getNetworkStats,
  getAllPersonNames,
};

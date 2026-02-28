/**
 * Neo4j service – uses the HTTP Query API v2 (works through any HTTPS proxy).
 * Provides a thin compatibility layer matching the neo4j-driver session API
 * so the rest of the codebase stays unchanged.
 *
 * v2 API endpoint: POST /db/<database>/query/v2
 * Response shape:  { data: { fields: [...], values: [[...], ...] }, bookmarks: [...] }
 */

// ---- Config ----------------------------------------------------------------

function getBase() {
  const raw = process.env.NEO4J_URI || '';
  // Convert bolt/neo4j+s URI to HTTPS host
  return raw
    .replace(/^neo4j\+s:\/\//, 'https://')
    .replace(/^neo4j:\/\//, 'http://')
    .replace(/^bolt\+s:\/\//, 'https://')
    .replace(/^bolt:\/\//, 'http://')
    .replace(/\/$/, '');
}

function getAuth() {
  const user = process.env.NEO4J_USER || 'neo4j';
  const pass = process.env.NEO4J_PASSWORD || '';
  return 'Basic ' + Buffer.from(`${user}:${pass}`).toString('base64');
}

const DB = process.env.NEO4J_DATABASE || 'neo4j';

// ---- Core HTTP request -----------------------------------------------------

async function queryApi(statement, parameters = {}) {
  const url = `${getBase()}/db/${DB}/query/v2`;

  const res = await fetch(url, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': getAuth(),
    },
    body: JSON.stringify({ statement, parameters }),
  });

  const data = await res.json();

  if (!res.ok || (data.errors && data.errors.length)) {
    const msg = data.errors ? data.errors[0].message : `HTTP ${res.status}`;
    throw new Error(msg);
  }

  return data.data; // { fields: [...], values: [[...], ...] }
}

// ---- Compatibility layer ----------------------------------------------------

class Record {
  constructor(fields, row) {
    this._fields = fields;
    this._row    = row;
  }
  get(field) {
    const i = this._fields.indexOf(field);
    return i >= 0 ? this._row[i] : undefined;
  }
}

class Result {
  constructor(fields, values) {
    this.records = (values || []).map(row => new Record(fields, row));
  }
}

class Session {
  async run(cypher, params = {}) {
    const data = await queryApi(cypher, params);
    return new Result(data.fields, data.values);
  }
  async close() {} // no-op for HTTP API
}

function getSession() {
  return new Session();
}

// ---- Health / setup --------------------------------------------------------

async function verifyConnection() {
  try {
    await queryApi('RETURN 1');
    console.log('Connected to Neo4j AuraDB via HTTPS API');
    return true;
  } catch (err) {
    console.error('Neo4j connection failed:', err.message);
    return false;
  }
}

async function initializeSchema() {
  const session = getSession();
  try {
    await session.run('CREATE INDEX IF NOT EXISTS FOR (p:Person)   ON (p.name)');
    await session.run('CREATE INDEX IF NOT EXISTS FOR (b:Building) ON (b.address)');
    await session.run('CREATE INDEX IF NOT EXISTS FOR (c:Company)  ON (c.name)');
    console.log('Neo4j schema indexes ready');
  } catch (err) {
    console.warn('Schema init warning:', err.message);
  }
}

module.exports = { getSession, verifyConnection, initializeSchema };

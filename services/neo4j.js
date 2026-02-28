const neo4j = require('neo4j-driver');

const driver = neo4j.driver(
  process.env.NEO4J_URI || 'bolt://localhost:7687',
  neo4j.auth.basic(
    process.env.NEO4J_USER || 'neo4j',
    process.env.NEO4J_PASSWORD || 'password'
  ),
  { disableLosslessIntegers: true }
);

function getSession() {
  return driver.session();
}

async function verifyConnection() {
  const session = getSession();
  try {
    await session.run('RETURN 1');
    console.log('Connected to Neo4j');
    return true;
  } catch (err) {
    console.error('Failed to connect to Neo4j:', err.message);
    return false;
  } finally {
    await session.close();
  }
}

async function initializeSchema() {
  const session = getSession();
  try {
    await session.run('CREATE INDEX IF NOT EXISTS FOR (p:Person) ON (p.name)');
    await session.run('CREATE INDEX IF NOT EXISTS FOR (b:Building) ON (b.address)');
    await session.run('CREATE INDEX IF NOT EXISTS FOR (c:Company) ON (c.name)');
    console.log('Neo4j schema indexes ready');
  } catch (err) {
    // Indexes may already exist or version may differ; non-fatal
    console.warn('Schema init warning:', err.message);
  } finally {
    await session.close();
  }
}

module.exports = { driver, getSession, verifyConnection, initializeSchema };

const { parse } = require('csv-parse/sync');
const fs = require('fs');
const { getSession } = require('./neo4j');

/**
 * Split a semicolon-delimited field, trimming whitespace and dropping empties.
 */
function splitField(val) {
  if (!val) return [];
  return val.split(';').map(s => s.trim()).filter(Boolean);
}

/**
 * Import a CSV file into Neo4j.
 * Expected columns (all optional except owner_name):
 *   owner_name, email, linkedin, twitter, instagram, facebook, phone,
 *   building_address, building_name, building_type,
 *   connections     – semicolon-separated list of person names
 *   family          – semicolon-separated "Name:relation" pairs
 *   work_history    – semicolon-separated "Company:Role:Years" tuples
 *   followers       – semicolon-separated list of person names (follow the owner)
 *   employer        – current employer shorthand
 */
async function importCSV(filePath) {
  const content = fs.readFileSync(filePath, 'utf8');
  const records = parse(content, {
    columns: true,
    skip_empty_lines: true,
    trim: true,
    relax_quotes: true,
  });

  const results = { imported: 0, skipped: 0, errors: [] };
  const session = getSession();

  for (const record of records) {
    const ownerName = (record.owner_name || record.name || record.Name || '').trim();
    if (!ownerName) {
      results.skipped++;
      continue;
    }
    try {
      await processRecord(session, record, ownerName);
      results.imported++;
    } catch (err) {
      results.errors.push({ record: ownerName, error: err.message });
    }
  }

  await session.close();
  try { fs.unlinkSync(filePath); } catch (_) {}
  return results;
}

async function processRecord(session, record, ownerName) {
  // Upsert owner Person node
  await session.run(
    `MERGE (p:Person {name: $name})
     SET p.email     = CASE WHEN $email     <> '' THEN $email     ELSE p.email     END,
         p.linkedin  = CASE WHEN $linkedin  <> '' THEN $linkedin  ELSE p.linkedin  END,
         p.twitter   = CASE WHEN $twitter   <> '' THEN $twitter   ELSE p.twitter   END,
         p.instagram = CASE WHEN $instagram <> '' THEN $instagram ELSE p.instagram END,
         p.facebook  = CASE WHEN $facebook  <> '' THEN $facebook  ELSE p.facebook  END,
         p.phone     = CASE WHEN $phone     <> '' THEN $phone     ELSE p.phone     END`,
    {
      name:      ownerName,
      email:     record.email     || '',
      linkedin:  record.linkedin  || '',
      twitter:   record.twitter   || '',
      instagram: record.instagram || '',
      facebook:  record.facebook  || '',
      phone:     record.phone     || '',
    }
  );

  // Building
  const addr = (record.building_address || '').trim();
  if (addr) {
    await session.run(
      `MERGE (b:Building {address: $address})
       SET b.name = CASE WHEN $bname <> '' THEN $bname ELSE b.name END,
           b.type = CASE WHEN $btype <> '' THEN $btype ELSE b.type END
       WITH b
       MATCH (p:Person {name: $owner})
       MERGE (p)-[:OWNS]->(b)`,
      {
        address: addr,
        bname:   (record.building_name || addr).trim(),
        btype:   (record.building_type || 'commercial').trim(),
        owner:   ownerName,
      }
    );
  }

  // Current employer shorthand
  const employer = (record.employer || '').trim();
  if (employer) {
    await session.run(
      `MERGE (c:Company {name: $company})
       WITH c
       MATCH (p:Person {name: $owner})
       MERGE (p)-[:WORKS_AT {role: 'employee', current: true}]->(c)`,
      { company: employer, owner: ownerName }
    );
  }

  // Connections (mutual acquaintances / known associates)
  for (const conn of splitField(record.connections)) {
    await session.run(
      `MERGE (c:Person {name: $connName})
       WITH c
       MATCH (p:Person {name: $owner})
       MERGE (p)-[:KNOWS]->(c)`,
      { connName: conn, owner: ownerName }
    );
  }

  // Family  "Name:relation" or just "Name"
  for (const member of splitField(record.family)) {
    const [memberName, relation = 'family'] = member.split(':').map(s => s.trim());
    if (!memberName) continue;
    await session.run(
      `MERGE (f:Person {name: $memberName})
       WITH f
       MATCH (p:Person {name: $owner})
       MERGE (p)-[:FAMILY_OF {relation: $relation}]->(f)`,
      { memberName, relation, owner: ownerName }
    );
  }

  // Work history  "Company:Role:Years" or subsets
  for (const job of splitField(record.work_history)) {
    const parts = job.split(':').map(s => s.trim());
    const [company, role = '', years = ''] = parts;
    if (!company) continue;
    await session.run(
      `MERGE (c:Company {name: $company})
       WITH c
       MATCH (p:Person {name: $owner})
       MERGE (p)-[w:WORKS_AT {role: $role}]->(c)
       SET w.years = $years`,
      { company, role, years, owner: ownerName }
    );
  }

  // Followers  – these people follow the owner
  for (const follower of splitField(record.followers)) {
    await session.run(
      `MERGE (f:Person {name: $followerName})
       WITH f
       MATCH (p:Person {name: $owner})
       MERGE (f)-[:FOLLOWS]->(p)`,
      { followerName: follower, owner: ownerName }
    );
  }
}

module.exports = { importCSV };

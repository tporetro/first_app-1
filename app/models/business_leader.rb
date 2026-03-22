# Represents a (:BusinessLeader) node in the graph.
#
# Graph schema
# ============
#   (:BusinessLeader {id, name, title, email, linkedin_url, bio, influence_score})
#     -[:WORKS_AT   {since, title, current}]->  (:Company)
#     -[:KNOWS      {since, source, strength}]-> (:BusinessLeader)
#     -[:BOARD_MEMBER_OF {since}]->              (:Company)
#     -[:PREVIOUSLY_WORKED_AT {from, to, title}]->(:Company)
#
class BusinessLeader
  attr_accessor :id, :name, :title, :email, :linkedin_url, :bio, :influence_score

  def initialize(attrs = {})
    attrs.each { |k, v| public_send(:"#{k}=", v) if respond_to?(:"#{k}=") }
  end

  # ── Finders ──────────────────────────────────────────────────────────────

  def self.all
    rows = db.query(<<~CYPHER)
      MATCH (l:BusinessLeader)
      OPTIONAL MATCH (l)-[:WORKS_AT {current: true}]->(c:Company)
      RETURN l.id AS id, l.name AS name, l.title AS title,
             l.email AS email, l.linkedin_url AS linkedin_url,
             l.bio AS bio, l.influence_score AS influence_score,
             c.name AS company_name
      ORDER BY l.name
    CYPHER
    rows.map { |r| from_row(r) }
  end

  def self.find(id)
    rows = db.query(<<~CYPHER, id: id)
      MATCH (l:BusinessLeader {id: $id})
      OPTIONAL MATCH (l)-[:WORKS_AT {current: true}]->(c:Company)
      RETURN l.id AS id, l.name AS name, l.title AS title,
             l.email AS email, l.linkedin_url AS linkedin_url,
             l.bio AS bio, l.influence_score AS influence_score,
             c.name AS company_name
    CYPHER
    rows.first ? from_row(rows.first) : nil
  end

  def self.search(query)
    q = "(?i).*#{Regexp.escape(query)}.*"
    rows = db.query(<<~CYPHER, q: ".*#{query.downcase}.*")
      MATCH (l:BusinessLeader)
      WHERE toLower(l.name) CONTAINS toLower($q)
         OR toLower(l.title) CONTAINS toLower($q)
      OPTIONAL MATCH (l)-[:WORKS_AT {current: true}]->(c:Company)
      RETURN l.id AS id, l.name AS name, l.title AS title,
             l.email AS email, l.linkedin_url AS linkedin_url,
             l.bio AS bio, l.influence_score AS influence_score,
             c.name AS company_name
      ORDER BY l.influence_score DESC
    CYPHER
    rows.map { |r| from_row(r) }
  end

  # ── Relationships ─────────────────────────────────────────────────────────

  # Direct connections (1st-degree KNOWS relationships)
  def connections
    rows = db.query(<<~CYPHER, id: id)
      MATCH (l:BusinessLeader {id: $id})-[r:KNOWS]-(other:BusinessLeader)
      OPTIONAL MATCH (other)-[:WORKS_AT {current: true}]->(c:Company)
      RETURN other.id AS id, other.name AS name, other.title AS title,
             other.email AS email, other.linkedin_url AS linkedin_url,
             other.bio AS bio, other.influence_score AS influence_score,
             c.name AS company_name,
             r.since AS connected_since, r.source AS source, r.strength AS strength
      ORDER BY r.strength DESC, other.name
    CYPHER
    rows.map { |r| from_row(r) }
  end

  # Current company
  def current_company
    rows = db.query(<<~CYPHER, id: id)
      MATCH (l:BusinessLeader {id: $id})-[:WORKS_AT {current: true}]->(c:Company)
      RETURN c.id AS id, c.name AS name, c.industry AS industry,
             c.size AS size, c.website AS website, c.hq_city AS hq_city
    CYPHER
    rows.first ? Company.from_row(rows.first) : nil
  end

  # Companies on whose board this leader sits
  def board_seats
    rows = db.query(<<~CYPHER, id: id)
      MATCH (l:BusinessLeader {id: $id})-[r:BOARD_MEMBER_OF]->(c:Company)
      RETURN c.id AS id, c.name AS name, c.industry AS industry,
             c.size AS size, c.website AS website, c.hq_city AS hq_city,
             r.since AS since
    CYPHER
    rows.map { |r| Company.from_row(r) }
  end

  # Work history
  def work_history
    rows = db.query(<<~CYPHER, id: id)
      MATCH (l:BusinessLeader {id: $id})-[r:PREVIOUSLY_WORKED_AT]->(c:Company)
      RETURN c.id AS id, c.name AS name, c.industry AS industry,
             c.size AS size, c.website AS website, c.hq_city AS hq_city,
             r.from AS from, r.to AS to, r.title AS title
      ORDER BY r.to DESC
    CYPHER
    rows
  end

  # Mutual connections between this leader and another
  def mutual_connections_with(other_id)
    rows = db.query(<<~CYPHER, id: id, other_id: other_id)
      MATCH (a:BusinessLeader {id: $id})-[:KNOWS]-(mutual:BusinessLeader)-[:KNOWS]-(b:BusinessLeader {id: $other_id})
      WHERE a <> b AND mutual <> a AND mutual <> b
      OPTIONAL MATCH (mutual)-[:WORKS_AT {current: true}]->(c:Company)
      RETURN DISTINCT mutual.id AS id, mutual.name AS name,
             mutual.title AS title, c.name AS company_name
      ORDER BY mutual.name
    CYPHER
    rows.map { |r| from_row(r) }
  end

  # ── Network / Path Analysis ───────────────────────────────────────────────

  # Find the shortest introduction path between this leader and a target.
  # Returns the ordered list of nodes in the chain.
  def introduction_path_to(target_id)
    rows = db.query(<<~CYPHER, source_id: id, target_id: target_id)
      MATCH path = shortestPath(
        (source:BusinessLeader {id: $source_id})-[:KNOWS*..6]-(target:BusinessLeader {id: $target_id})
      )
      UNWIND nodes(path) AS node
      OPTIONAL MATCH (node)-[:WORKS_AT {current: true}]->(c:Company)
      RETURN node.id AS id, node.name AS name, node.title AS title,
             c.name AS company_name
    CYPHER
    rows.map { |r| from_row(r) }
  end

  # Degree of separation (hop count) to another leader
  def degrees_to(target_id)
    rows = db.query(<<~CYPHER, source_id: id, target_id: target_id)
      MATCH path = shortestPath(
        (source:BusinessLeader {id: $source_id})-[:KNOWS*..10]-(target:BusinessLeader {id: $target_id})
      )
      RETURN length(path) AS hops
    CYPHER
    rows.first ? rows.first['hops'] : nil
  end

  # Leaders reachable within N hops (default 2) — useful for B2B targeting
  def network_within(hops = 2)
    rows = db.query(<<~CYPHER, id: id, hops: hops)
      MATCH (source:BusinessLeader {id: $id})-[:KNOWS*1..$hops]-(reachable:BusinessLeader)
      WHERE source <> reachable
      OPTIONAL MATCH (reachable)-[:WORKS_AT {current: true}]->(c:Company)
      RETURN DISTINCT reachable.id AS id, reachable.name AS name,
             reachable.title AS title, c.name AS company_name,
             reachable.influence_score AS influence_score
      ORDER BY reachable.influence_score DESC
    CYPHER
    rows.map { |r| from_row(r) }
  end

  # ── Persistence ───────────────────────────────────────────────────────────

  def self.create(attrs)
    attrs[:id] ||= SecureRandom.uuid
    attrs[:influence_score] ||= 0
    db.query(<<~CYPHER, attrs.transform_keys(&:to_s))
      CREATE (l:BusinessLeader {
        id:              $id,
        name:            $name,
        title:           $title,
        email:           $email,
        linkedin_url:    $linkedin_url,
        bio:             $bio,
        influence_score: toInteger($influence_score)
      })
      RETURN l.id AS id
    CYPHER
    find(attrs[:id])
  end

  def self.connect(leader_id_a, leader_id_b, since: nil, source: 'manual', strength: 5)
    db.query(<<~CYPHER, a: leader_id_a, b: leader_id_b, since: since, source: source, strength: strength)
      MATCH (a:BusinessLeader {id: $a}), (b:BusinessLeader {id: $b})
      MERGE (a)-[:KNOWS {since: $since, source: $source, strength: $strength}]->(b)
    CYPHER
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  def self.from_row(row)
    leader = new(row)
    leader.id ||= row['id']
    leader
  end

  def self.db
    NEO4J
  end

  def db
    self.class.db
  end

  def to_param
    id
  end
end

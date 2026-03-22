# Represents a (:Company) node in the graph.
#
# A company is the anchor for employment and board membership relationships.
# Industry segmentation enables B2B targeting ("show me all leaders in FinTech").
class Company
  attr_accessor :id, :name, :industry, :size, :website, :hq_city, :description
  # Extra attrs surfaced by some queries
  attr_accessor :since, :from, :to, :role_title

  def initialize(attrs = {})
    attrs.each { |k, v| public_send(:"#{k}=", v) if respond_to?(:"#{k}=") }
  end

  # ── Finders ──────────────────────────────────────────────────────────────

  def self.all
    rows = db.query(<<~CYPHER)
      MATCH (c:Company)
      RETURN c.id AS id, c.name AS name, c.industry AS industry,
             c.size AS size, c.website AS website, c.hq_city AS hq_city,
             c.description AS description
      ORDER BY c.name
    CYPHER
    rows.map { |r| from_row(r) }
  end

  def self.find(id)
    rows = db.query(<<~CYPHER, id: id)
      MATCH (c:Company {id: $id})
      RETURN c.id AS id, c.name AS name, c.industry AS industry,
             c.size AS size, c.website AS website, c.hq_city AS hq_city,
             c.description AS description
    CYPHER
    rows.first ? from_row(rows.first) : nil
  end

  def self.by_industry(industry)
    rows = db.query(<<~CYPHER, industry: industry)
      MATCH (c:Company {industry: $industry})
      RETURN c.id AS id, c.name AS name, c.industry AS industry,
             c.size AS size, c.website AS website, c.hq_city AS hq_city,
             c.description AS description
      ORDER BY c.name
    CYPHER
    rows.map { |r| from_row(r) }
  end

  def self.industries
    rows = db.query(<<~CYPHER)
      MATCH (c:Company)
      RETURN DISTINCT c.industry AS industry
      ORDER BY industry
    CYPHER
    rows.map { |r| r['industry'] }.compact
  end

  # ── Relationships ─────────────────────────────────────────────────────────

  # Current employees
  def current_employees
    rows = db.query(<<~CYPHER, id: id)
      MATCH (l:BusinessLeader)-[:WORKS_AT {current: true}]->(c:Company {id: $id})
      RETURN l.id AS id, l.name AS name, l.title AS title,
             l.email AS email, l.linkedin_url AS linkedin_url,
             l.bio AS bio, l.influence_score AS influence_score
      ORDER BY l.influence_score DESC
    CYPHER
    rows.map { |r| BusinessLeader.from_row(r) }
  end

  # Board members
  def board_members
    rows = db.query(<<~CYPHER, id: id)
      MATCH (l:BusinessLeader)-[r:BOARD_MEMBER_OF]->(c:Company {id: $id})
      RETURN l.id AS id, l.name AS name, l.title AS title,
             l.email AS email, l.linkedin_url AS linkedin_url,
             l.bio AS bio, l.influence_score AS influence_score,
             r.since AS since
      ORDER BY l.name
    CYPHER
    rows.map { |r| BusinessLeader.from_row(r) }
  end

  # Alumni (previously worked here)
  def alumni
    rows = db.query(<<~CYPHER, id: id)
      MATCH (l:BusinessLeader)-[r:PREVIOUSLY_WORKED_AT]->(c:Company {id: $id})
      RETURN l.id AS id, l.name AS name, l.title AS title,
             l.email AS email, l.linkedin_url AS linkedin_url,
             l.bio AS bio, l.influence_score AS influence_score,
             r.from AS from, r.to AS to, r.title AS role_title
      ORDER BY r.to DESC, l.name
    CYPHER
    rows.map { |r| BusinessLeader.from_row(r) }
  end

  # ── Persistence ───────────────────────────────────────────────────────────

  def self.create(attrs)
    attrs[:id] ||= SecureRandom.uuid
    db.query(<<~CYPHER, attrs.transform_keys(&:to_s))
      CREATE (c:Company {
        id:          $id,
        name:        $name,
        industry:    $industry,
        size:        $size,
        website:     $website,
        hq_city:     $hq_city,
        description: $description
      })
      RETURN c.id AS id
    CYPHER
    find(attrs[:id])
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  def self.from_row(row)
    new(row)
  end

  def self.db
    NEO4J
  end

  def to_param
    id
  end
end

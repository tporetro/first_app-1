# High-level B2B intelligence queries that span the whole graph
class NetworkController < ApplicationController
  # GET /network
  # Dashboard with top influencers and recent stats
  def index
    @top_leaders = NEO4J.query(<<~CYPHER)
      MATCH (l:BusinessLeader)
      OPTIONAL MATCH (l)-[:WORKS_AT {current: true}]->(c:Company)
      RETURN l.id AS id, l.name AS name, l.title AS title,
             c.name AS company_name, l.influence_score AS influence_score
      ORDER BY l.influence_score DESC
      LIMIT 10
    CYPHER

    @stats = {
      leaders:       NEO4J.query('MATCH (l:BusinessLeader) RETURN count(l) AS n').first&.fetch('n', 0),
      companies:     NEO4J.query('MATCH (c:Company) RETURN count(c) AS n').first&.fetch('n', 0),
      connections:   NEO4J.query('MATCH ()-[r:KNOWS]->() RETURN count(r) AS n').first&.fetch('n', 0),
      board_seats:   NEO4J.query('MATCH ()-[r:BOARD_MEMBER_OF]->() RETURN count(r) AS n').first&.fetch('n', 0),
    }

    @industries = NEO4J.query(<<~CYPHER)
      MATCH (c:Company)<-[:WORKS_AT {current: true}]-(l:BusinessLeader)
      RETURN c.industry AS industry, count(DISTINCT l) AS leader_count
      ORDER BY leader_count DESC
    CYPHER
  end

  # GET /network/top_connectors
  # Business leaders with the most connections — the key "bridge nodes" for
  # reaching new prospects (the warm-intro strategy described in the article)
  def top_connectors
    @connectors = NEO4J.query(<<~CYPHER)
      MATCH (l:BusinessLeader)-[:KNOWS]-(other)
      WITH l, count(DISTINCT other) AS degree
      OPTIONAL MATCH (l)-[:WORKS_AT {current: true}]->(c:Company)
      RETURN l.id AS id, l.name AS name, l.title AS title,
             c.name AS company_name, l.influence_score AS influence_score,
             degree
      ORDER BY degree DESC
      LIMIT 20
    CYPHER
  end

  # GET /network/by_industry?industry=FinTech
  # All leaders in a given industry with their connection counts —
  # the primary B2B targeting view
  def by_industry
    @industry = params[:industry]
    return redirect_to network_path unless @industry.present?

    @leaders = NEO4J.query(<<~CYPHER, industry: @industry)
      MATCH (l:BusinessLeader)-[:WORKS_AT {current: true}]->(c:Company {industry: $industry})
      OPTIONAL MATCH (l)-[:KNOWS]-(other)
      WITH l, c, count(DISTINCT other) AS connections
      RETURN l.id AS id, l.name AS name, l.title AS title,
             c.name AS company_name, l.influence_score AS influence_score,
             connections
      ORDER BY connections DESC, l.influence_score DESC
    CYPHER

    @industries = NEO4J.query(<<~CYPHER)
      MATCH (c:Company)
      RETURN DISTINCT c.industry AS industry ORDER BY industry
    CYPHER
  end
end

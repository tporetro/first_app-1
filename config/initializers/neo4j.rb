require_relative '../../lib/neo4j/client'

# Shared Neo4j client instance — configure via environment variables:
#   NEO4J_URL       (default: http://localhost:7474)
#   NEO4J_USERNAME  (default: neo4j)
#   NEO4J_PASSWORD  (default: password)
NEO4J = Neo4j::Client.new

# Schema / index creation runs once at boot.
# Using Neo4j 2.x+ constraint + index syntax.
SCHEMA_STATEMENTS = [
  # Uniqueness constraints implicitly create an index
  'CREATE CONSTRAINT ON (l:BusinessLeader) ASSERT l.id IS UNIQUE',
  'CREATE CONSTRAINT ON (c:Company)        ASSERT c.id IS UNIQUE',
  'CREATE CONSTRAINT ON (i:Industry)       ASSERT i.name IS UNIQUE',

  # Extra index for fast full-text-style searches
  'CREATE INDEX ON :BusinessLeader(name)',
  'CREATE INDEX ON :BusinessLeader(email)',
  'CREATE INDEX ON :Company(name)',
].freeze

begin
  SCHEMA_STATEMENTS.each do |stmt|
    begin
      NEO4J.query(stmt)
    rescue Neo4j::Client::QueryError => e
      # Ignore "already exists" errors on repeated boots
      raise unless e.message.include?('already exists') || e.message.include?('Equivalent index')
    end
  end
rescue => e
  Rails.logger.warn "[Neo4j] Schema setup skipped: #{e.message}"
end

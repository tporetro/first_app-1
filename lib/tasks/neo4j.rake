require_relative '../neo4j/client'

namespace :neo4j do
  desc "Verify Neo4j connection and print graph stats"
  task :status => :environment do
    if NEO4J.connected?
      puts "Neo4j: connected (#{ENV.fetch('NEO4J_URL', 'http://localhost:7474')})"
      {
        "BusinessLeader nodes" => "MATCH (l:BusinessLeader) RETURN count(l) AS n",
        "Company nodes"        => "MATCH (c:Company) RETURN count(c) AS n",
        "KNOWS relationships"  => "MATCH ()-[r:KNOWS]->() RETURN count(r) AS n",
        "WORKS_AT rels"        => "MATCH ()-[r:WORKS_AT]->() RETURN count(r) AS n",
        "BOARD_MEMBER_OF rels" => "MATCH ()-[r:BOARD_MEMBER_OF]->() RETURN count(r) AS n",
      }.each do |label, cypher|
        count = NEO4J.query(cypher).first&.fetch('n', 0)
        printf "  %-26s %d\n", label, count
      end
    else
      puts "Neo4j: NOT reachable at #{ENV.fetch('NEO4J_URL', 'http://localhost:7474')}"
      puts "  Start Neo4j and set NEO4J_URL, NEO4J_USERNAME, NEO4J_PASSWORD env vars."
      exit 1
    end
  end

  desc "Drop all nodes and relationships from the graph"
  task :reset => :environment do
    print "This will delete ALL graph data. Type 'yes' to confirm: "
    input = $stdin.gets.chomp
    if input == 'yes'
      NEO4J.query("MATCH (n) DETACH DELETE n")
      puts "Graph cleared."
    else
      puts "Aborted."
    end
  end

  desc "Run an arbitrary Cypher query (CYPHER=... rake neo4j:query)"
  task :query => :environment do
    cypher = ENV['CYPHER']
    abort "Usage: CYPHER='MATCH ...' rake neo4j:query" unless cypher.present?
    results = NEO4J.query(cypher)
    if results.empty?
      puts "(no results)"
    else
      puts results.map(&:inspect).join("\n")
    end
  end

  desc "Show all top connectors (most connections)"
  task :top_connectors => :environment do
    rows = NEO4J.query(<<~CYPHER)
      MATCH (l:BusinessLeader)-[:KNOWS]-(other)
      WITH l, count(DISTINCT other) AS degree
      RETURN l.name AS name, l.title AS title, degree
      ORDER BY degree DESC LIMIT 10
    CYPHER
    rows.each { |r| printf "  %-25s %-30s %d connections\n", r['name'], r['title'], r['degree'] }
  end
end

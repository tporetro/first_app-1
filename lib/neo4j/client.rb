require 'net/http'
require 'json'
require 'uri'

# Neo4j HTTP API client
# Talks to the Neo4j transactional Cypher HTTP endpoint.
# Configure via config/initializers/neo4j.rb or environment variables.
module Neo4j
  class Client
    BOLT_DEFAULT = 'http://localhost:7474'.freeze

    class QueryError < StandardError
      attr_reader :code
      def initialize(msg, code = nil)
        super(msg)
        @code = code
      end
    end

    def initialize(url: nil, username: nil, password: nil)
      @url      = url      || ENV.fetch('NEO4J_URL',      BOLT_DEFAULT)
      @username = username || ENV.fetch('NEO4J_USERNAME', 'neo4j')
      @password = password || ENV.fetch('NEO4J_PASSWORD', 'password')
    end

    # Execute a single Cypher query and return array of result rows.
    # Each row is a hash keyed by the column names.
    def query(cypher, params = {})
      uri = URI("#{@url}/db/data/transaction/commit")
      http = Net::HTTP.new(uri.host, uri.port)

      request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
      request.basic_auth(@username, @password)
      request.body = JSON.generate(
        statements: [{ statement: cypher, parameters: params }]
      )

      response = http.request(request)
      parsed = JSON.parse(response.body)

      errors = parsed['errors'] || []
      raise QueryError.new(errors.first['message'], errors.first['code']) if errors.any?

      results = parsed['results'].first || {}
      columns = results['columns'] || []
      rows    = results['data']    || []

      rows.map do |row|
        columns.zip(row['row']).to_h
      end
    end

    # Run multiple queries in a single transaction
    def batch(statements)
      uri = URI("#{@url}/db/data/transaction/commit")
      http = Net::HTTP.new(uri.host, uri.port)

      request = Net::HTTP::Post.new(uri.path, 'Content-Type' => 'application/json')
      request.basic_auth(@username, @password)
      request.body = JSON.generate(
        statements: statements.map { |s| { statement: s[:cypher], parameters: s[:params] || {} } }
      )

      response = http.request(request)
      parsed = JSON.parse(response.body)

      errors = parsed['errors'] || []
      raise QueryError.new(errors.first['message'], errors.first['code']) if errors.any?

      parsed['results']
    end

    def connected?
      uri = URI("#{@url}/db/data/")
      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Get.new(uri.path)
      request.basic_auth(@username, @password)
      response = http.request(request)
      response.code.to_i == 200
    rescue
      false
    end
  end
end

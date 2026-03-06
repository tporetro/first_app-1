require 'net/http'
require 'uri'
require 'json'

# Contact enrichment via People Data Labs (PDL) Person Search API.
# Docs: https://docs.peopledatalabs.com/docs/person-search-api
#
# Credentials: PDL_API_KEY environment variable
#
# What it finds:
#   - Owner/officer full name + title (CEO, Managing Member, etc.)
#   - Work email + phone
#   - LinkedIn URL
#   - Company domain
#
# Uses the person search endpoint filtered by company name + senior titles
# so we get the decision-maker, not a random employee.
class PeopleDataLabsService
  API_URL = 'https://api.peopledatalabs.com/v5/person/search'.freeze
  TIMEOUT = 20

  # Titles for people authorized to file or approve insurance claims on commercial property
  CLAIM_DECISION_TITLES = [
    'owner', 'managing member', 'member manager',
    'president', 'ceo', 'chief executive officer',
    'principal', 'partner', 'co-founder', 'founder',
    'asset manager', 'risk manager', 'insurance manager',
    'vp operations', 'chief operating officer', 'coo',
    'property manager', 'facilities director'
  ].freeze

  Result = Struct.new(
    :human_owner_name, :owner_title, :owner_email,
    :owner_phone, :owner_linkedin, :org_domain,
    keyword_init: true
  )

  # Returns a Result or nil. Never raises.
  def self.enrich(owner_entity:, state: nil)
    api_key = ENV['PDL_API_KEY']
    unless api_key
      Rails.logger.warn 'PeopleDataLabs: PDL_API_KEY not set'
      return nil
    end

    # PDL uses Elasticsearch DSL for person search
    must = [
      { match: { 'job_company_name' => owner_entity } }
    ]
    must << { term: { 'job_company_location_region' => state.downcase } } if state.present?

    sql = build_sql(owner_entity, state)

    body = {
      sql:      sql,
      size:     1,
      pretty:   false
    }

    resp = post_json(body, api_key)
    return nil unless resp

    person = resp.dig('data', 0)
    return nil unless person

    build_result(person)
  rescue StandardError => e
    Rails.logger.error "PeopleDataLabs error for #{owner_entity}: #{e.message}"
    nil
  end

  private

  def self.build_sql(owner_entity, state)
    company = owner_entity.to_s.gsub("'", "''")
    titles  = CLAIM_DECISION_TITLES.map { |t| "'#{t}'" }.join(', ')
    state_clause = state.present? ? " AND job_company_location_region = '#{state.downcase}'" : ''
    "SELECT * FROM person WHERE job_company_name LIKE '%#{company}%'#{state_clause} AND job_title_levels IN ('c_suite', 'owner', 'partner', 'vp', 'director') AND job_company_industry IN ('real estate', 'commercial real estate', 'property management', 'investment management') LIMIT 1"
  end

  def self.build_result(person)
    full_name = [person['first_name'], person['last_name']].compact.join(' ').presence ||
                person['full_name']

    email = person.dig('work_email') ||
            person['emails']&.find { |e| e['type'] == 'professional' }&.dig('address') ||
            person['emails']&.first&.dig('address')

    phone = person['phone_numbers']&.first

    Result.new(
      human_owner_name: full_name,
      owner_title:      person['job_title'],
      owner_email:      email,
      owner_phone:      phone,
      owner_linkedin:   person['linkedin_url'],
      org_domain:       person.dig('job_company_website')
    )
  end

  def self.post_json(body, api_key)
    uri  = URI.parse(API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = true
    http.read_timeout = TIMEOUT

    req = Net::HTTP::Post.new(uri.path)
    req['Content-Type'] = 'application/json'
    req['X-Api-Key']    = api_key
    req.body = body.to_json

    resp = http.request(req)
    unless resp.is_a?(Net::HTTPSuccess)
      Rails.logger.warn "PDL #{resp.code}: #{resp.body.to_s.truncate(200)}"
      return nil
    end

    JSON.parse(resp.body)
  rescue JSON::ParserError => e
    Rails.logger.error "PDL JSON parse error: #{e.message}"
    nil
  end
end

require 'net/http'
require 'uri'
require 'json'

# Phase 3 — Contact Enrichment via Apollo.io
# Searches for owner/principal contacts by company name.
# POST https://api.apollo.io/v1/mixed_people/search
class ApolloService
  API_URL = 'https://api.apollo.io/api/v1/mixed_people/search'.freeze

  ENRICHED_FIELDS = %i[
    human_owner_name owner_title owner_email
    owner_phone owner_linkedin parent_company org_domain
  ].freeze

  # Returns enriched contact hash for a given owner_entity, or nil if not found.
  def self.enrich(owner_entity:)
    api_key = ENV['APOLLO_API_KEY']
    raise 'APOLLO_API_KEY not set' unless api_key

    payload = {
      q_organization_name: owner_entity,
      page: 1,
      per_page: 1,
      person_titles: ['CEO', 'President', 'Managing Member', 'Managing Director',
                      'Owner', 'Principal', 'VP', 'Director']
    }

    response = post_json(API_URL, payload, api_key)
    return nil unless response

    person = response.dig('people', 0)
    return nil unless person

    {
      human_owner_name: [person['first_name'], person['last_name']].compact.join(' '),
      owner_title:      person['title'],
      owner_email:      person['email'],
      owner_phone:      person['phone_numbers']&.first&.dig('sanitized_number'),
      owner_linkedin:   person['linkedin_url'],
      parent_company:   person.dig('organization', 'name'),
      org_domain:       person.dig('organization', 'website_url'),
      enrichment_source: 'apollo'
    }
  rescue StandardError => e
    Rails.logger.error "Apollo enrichment error for #{owner_entity}: #{e.message}"
    nil
  end

  private

  def self.post_json(url, payload, api_key)
    uri  = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 20

    request = Net::HTTP::Post.new(uri.path)
    request['Content-Type'] = 'application/json'
    request['X-Api-Key']    = api_key
    request.body = payload.to_json

    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      Rails.logger.warn "Apollo API #{response.code}: #{response.body.truncate(200)}"
      return nil
    end
    JSON.parse(response.body)
  end
end

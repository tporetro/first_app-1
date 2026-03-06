require 'net/http'
require 'uri'
require 'json'

# Primary enrichment via Clay's Enrichment API.
# Clay waterfalls through 50+ data providers (Hunter, Clearbit, PeopleDataLabs,
# Zoominfo, LinkedIn, etc.) and returns the best available data with email verification.
#
# Docs: https://docs.clay.com/reference/enrichment-api
# API key: https://app.clay.com/settings/api
#
# Setup in Clay: create a Table, add columns for the fields below,
# then get the Table API endpoint from Clay → Table Settings → API.
class ClayEnrichmentService
  # Clay's "People Enrichment" API — finds decision-maker by company name/domain
  PEOPLE_API_URL  = 'https://api.clay.com/v1/enrichments/people'.freeze
  # Clay's "Company Enrichment" API — finds company info, domain, parent company
  COMPANY_API_URL = 'https://api.clay.com/v1/enrichments/companies'.freeze

  def self.enrich(owner_entity:, address: nil, state: nil, domain: nil)
    api_key = ENV['CLAY_API_KEY']
    raise 'CLAY_API_KEY not set' unless api_key

    # Step 1: Company enrichment to find domain and parent company.
    # Skip if domain is already known (passed in from web search).
    company_data = if domain.present?
      { org_domain: domain }
    else
      enrich_company(owner_entity: owner_entity, api_key: api_key)
    end

    # Step 2: People enrichment to find decision-maker using company context
    resolved_domain = domain.presence || company_data&.dig(:org_domain)
    people_data = enrich_person(
      company_name: owner_entity,
      domain:       resolved_domain,
      api_key:      api_key,
      titles:       decision_maker_titles
    )

    merge_results(company_data, people_data)
  rescue StandardError => e
    Rails.logger.error "Clay enrichment failed for #{owner_entity}: #{e.message}"
    nil
  end

  private

  DECISION_MAKER_TITLES = [
    'CEO', 'President', 'Owner', 'Managing Member', 'Managing Director',
    'Principal', 'Partner', 'Founder', 'General Partner', 'Chief Executive Officer'
  ].freeze

  def self.decision_maker_titles = DECISION_MAKER_TITLES

  def self.enrich_company(owner_entity:, api_key:)
    payload = {
      company_name: owner_entity,
      enrich: {
        website:        true,
        linkedin:       true,
        description:    true,
        parent_company: true,
        employee_count: false
      }
    }

    response = post_json(COMPANY_API_URL, payload, api_key)
    return nil unless response

    {
      org_domain:     response.dig('data', 'website') || response.dig('data', 'domain'),
      parent_company: response.dig('data', 'parent_company', 'name'),
      company_linkedin: response.dig('data', 'linkedin_url')
    }.compact
  end

  def self.enrich_person(company_name:, domain:, api_key:, titles:)
    payload = {
      company_name: company_name,
      company_domain: domain,
      seniority: ['c_suite', 'owner', 'partner', 'vp'],
      titles: titles,
      enrich: {
        email:        true,
        phone:        true,
        linkedin:     true,
        verified_email: true  # Clay verifies deliverability
      }
    }

    response = post_json(PEOPLE_API_URL, payload, api_key)
    return nil unless response

    person = response.dig('data', 'people', 0) || response.dig('data')
    return nil unless person

    {
      human_owner_name: [person['first_name'], person['last_name']].compact.join(' ').presence,
      owner_title:      person['title'],
      owner_email:      person.dig('email', 'email') || person['email'],
      owner_phone:      person.dig('phone_numbers', 0, 'number') || person['phone'],
      owner_linkedin:   person['linkedin_url'],
      email_verified:   person.dig('email', 'verified') == true
    }.compact
  end

  def self.merge_results(company_data, people_data)
    return nil if company_data.nil? && people_data.nil?

    result = {}
    result.merge!(company_data || {})
    result.merge!(people_data || {})
    result
  end

  def self.post_json(url, payload, api_key)
    uri  = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30  # Clay can be slow on cold enrichments

    req = Net::HTTP::Post.new(uri.path)
    req['Authorization'] = "Bearer #{api_key}"
    req['Content-Type']  = 'application/json'
    req.body = payload.to_json

    resp = http.request(req)
    if resp.is_a?(Net::HTTPSuccess)
      JSON.parse(resp.body)
    else
      Rails.logger.warn "Clay API #{resp.code}: #{resp.body.truncate(200)}"
      nil
    end
  end
end

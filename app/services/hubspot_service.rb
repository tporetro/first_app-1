require 'net/http'
require 'uri'
require 'json'

# CRM sync — creates/updates HubSpot contacts and deals for enriched leads.
class HubspotService
  API_BASE = 'https://api.hubapi.com'.freeze

  # Upsert a contact by email. Returns HubSpot contact id or nil.
  def self.upsert_contact(lead:)
    token = ENV['HUBSPOT_ACCESS_TOKEN']
    raise 'HUBSPOT_ACCESS_TOKEN not set' unless token

    email = lead[:owner_email]
    return nil unless email

    properties = {
      email:      email,
      firstname:  lead[:human_owner_name]&.split&.first,
      lastname:   lead[:human_owner_name]&.split&.last,
      jobtitle:   lead[:owner_title],
      phone:      lead[:owner_phone],
      company:    lead[:owner_entity] || lead[:parent_company],
      website:    lead[:org_domain],
      hs_linkedin_url: lead[:owner_linkedin]
    }.compact

    # Try PATCH first (update by email), then POST (create)
    response = patch_contact(email, properties, token) || create_contact(properties, token)
    response&.dig('id')
  rescue StandardError => e
    Rails.logger.error "HubSpot upsert error: #{e.message}"
    nil
  end

  private

  def self.patch_contact(email, properties, token)
    uri  = URI.parse("#{API_BASE}/crm/v3/objects/contacts/#{URI.encode_www_form_component(email)}?idProperty=email")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req  = Net::HTTP::Patch.new(uri)
    req['Authorization'] = "Bearer #{token}"
    req['Content-Type']  = 'application/json'
    req.body = { properties: properties }.to_json
    resp = http.request(req)
    JSON.parse(resp.body) if resp.is_a?(Net::HTTPSuccess)
  end

  def self.create_contact(properties, token)
    uri  = URI.parse("#{API_BASE}/crm/v3/objects/contacts")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req  = Net::HTTP::Post.new(uri.path)
    req['Authorization'] = "Bearer #{token}"
    req['Content-Type']  = 'application/json'
    req.body = { properties: properties }.to_json
    resp = http.request(req)
    JSON.parse(resp.body) if resp.code.to_i == 201
  end
end

require 'net/http'
require 'uri'
require 'json'

# Property record lookup and skip-trace via PropStream API.
#
# Credentials:  PROPSTREAM_USERNAME / PROPSTREAM_PASSWORD  (your web login)
# Optional:     PROPSTREAM_SKIP_TRACE=true  — orders skip trace to get phone/email
#               (each skip trace costs ~$0.12 per record)
#
# What PropStream adds to the pipeline:
#   - Deed-verified owner name + mailing address (better than CAD data)
#   - Owner entity type (LLC, individual, trust, etc.)
#   - Skip-trace phone and email
#   - Equity / lender info useful for prioritisation
#
# Docs: PropStream API is undocumented publicly; endpoints reverse-engineered
# from their web app traffic. Tested against production as of 2025.
class PropStreamService
  BASE_URL       = 'https://api.propstream.com'.freeze
  TIMEOUT        = 20   # seconds per HTTP call
  TOKEN_TTL      = 3600 # re-auth after 1 hour

  # Cache auth token process-wide so we don't re-login on every enrichment call.
  @token         = nil
  @token_fetched = nil

  Result = Struct.new(
    :owner_name,          # deed owner name (may be LLC or person)
    :owner_mailing_address,
    :owner_email,
    :owner_phone,
    :owner_is_individual, # true if owner appears to be a person, not an entity
    :property_address,
    :bedrooms, :bathrooms, :sqft, :year_built,
    :estimated_value, :equity_percent,
    keyword_init: true
  )

  # Look up a property by address and optionally skip-trace the owner.
  # Returns a Result or nil on failure.
  def self.lookup(address:, city: nil, state: nil, zip: nil, skip_trace: false)
    token = auth_token
    return nil unless token

    prop = find_property(address: address, city: city, state: state, zip: zip, token: token)
    return nil unless prop

    result = build_result(prop)

    if skip_trace && ENV['PROPSTREAM_SKIP_TRACE'] == 'true'
      contact = run_skip_trace(prop_id: prop['id'], token: token)
      if contact
        result.owner_email = contact[:email]
        result.owner_phone = contact[:phone]
      end
    end

    result
  rescue StandardError => e
    Rails.logger.error "PropStreamService error: #{e.message}"
    nil
  end

  private

  def self.auth_token
    if @token && @token_fetched && (Time.now - @token_fetched) < TOKEN_TTL
      return @token
    end

    username = ENV['PROPSTREAM_USERNAME']
    password = ENV['PROPSTREAM_PASSWORD']
    unless username && password
      Rails.logger.warn 'PropStream: PROPSTREAM_USERNAME / PROPSTREAM_PASSWORD not set'
      return nil
    end

    resp = post_json('/login', {
      username: username,
      password: password
    }, token: nil)

    return nil unless resp

    @token         = resp['accessToken'] || resp['access_token'] || resp['token']
    @token_fetched = Time.now

    unless @token
      Rails.logger.error 'PropStream login succeeded but no token in response'
      return nil
    end

    @token
  rescue StandardError => e
    Rails.logger.error "PropStream auth failed: #{e.message}"
    nil
  end

  def self.find_property(address:, city:, state:, zip:, token:)
    params = { address: address }
    params[:city]  = city  if city
    params[:state] = state if state
    params[:zip]   = zip   if zip

    resp = get_json('/properties/search', params, token)
    return nil unless resp

    properties = resp['properties'] || resp['results'] || (resp.is_a?(Array) ? resp : nil)
    return nil if properties.nil? || properties.empty?

    # Return the best match (first result — PropStream ranks by relevance)
    properties.first
  end

  def self.run_skip_trace(prop_id:, token:)
    resp = post_json('/skip-trace/order', { propertyIds: [prop_id] }, token: token)
    return nil unless resp

    # PropStream returns skip-trace results asynchronously or synchronously
    # depending on the account tier. Try synchronous path first.
    contacts = resp.dig('results', 0, 'contacts') ||
               resp.dig('data', 0, 'contacts') ||
               resp['contacts']
    return nil unless contacts

    best = contacts.first
    return nil unless best

    {
      email: best['email'] || best.dig('emails', 0, 'email'),
      phone: best['phone'] || best.dig('phones', 0, 'number')
    }.compact
  end

  def self.build_result(prop)
    owner_name = prop.dig('owner', 'name') ||
                 prop['ownerName'] ||
                 prop['owner_name']

    Result.new(
      owner_name:            owner_name,
      owner_mailing_address: format_address(prop['ownerMailingAddress'] || prop.dig('owner', 'mailingAddress')),
      owner_email:           nil,
      owner_phone:           nil,
      owner_is_individual:   individual_owner?(owner_name),
      property_address:      format_address(prop['address'] || prop['propertyAddress']),
      bedrooms:              prop['bedrooms'] || prop.dig('characteristics', 'bedrooms'),
      bathrooms:             prop['bathrooms'] || prop.dig('characteristics', 'bathrooms'),
      sqft:                  prop['sqft'] || prop['livingSquareFeet'] || prop.dig('characteristics', 'livingArea'),
      year_built:            prop['yearBuilt'] || prop.dig('characteristics', 'yearBuilt'),
      estimated_value:       prop['estimatedValue'] || prop['avm'] || prop.dig('valuation', 'estimatedValue'),
      equity_percent:        prop['equityPercent'] || prop.dig('equity', 'percent')
    )
  end

  # Heuristic: names without LLC/Inc/Corp/Trust keywords are likely individuals
  ENTITY_KEYWORDS = %w[LLC INC CORP CORPORATION TRUST LP LLP LTD COMPANY CO PARTNERS].freeze

  def self.individual_owner?(name)
    return false if name.blank?
    upcased = name.upcase
    ENTITY_KEYWORDS.none? { |kw| upcased.include?(kw) }
  end

  def self.format_address(addr)
    return nil unless addr
    return addr if addr.is_a?(String)

    [
      addr['street'] || addr['streetAddress'],
      addr['city'],
      addr['state'],
      addr['zip'] || addr['zipCode']
    ].compact.join(', ')
  end

  # --- HTTP helpers ---

  def self.get_json(path, params, token)
    uri = URI.parse("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params) if params.any?

    req = Net::HTTP::Get.new(uri)
    req['Authorization'] = "Bearer #{token}" if token
    req['Accept'] = 'application/json'

    execute(uri, req)
  end

  def self.post_json(path, body, token:)
    uri = URI.parse("#{BASE_URL}#{path}")
    req = Net::HTTP::Post.new(uri.path)
    req['Authorization'] = "Bearer #{token}" if token
    req['Content-Type']  = 'application/json'
    req['Accept']        = 'application/json'
    req.body = body.to_json

    execute(uri, req)
  end

  def self.execute(uri, req)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = TIMEOUT

    resp = http.request(req)
    unless resp.is_a?(Net::HTTPSuccess)
      Rails.logger.warn "PropStream #{req.path} → #{resp.code}: #{resp.body.to_s.truncate(200)}"
      return nil
    end

    JSON.parse(resp.body)
  rescue JSON::ParserError => e
    Rails.logger.error "PropStream JSON parse error: #{e.message}"
    nil
  end
end

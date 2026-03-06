require 'anthropic'

# Intelligent multi-source contact enrichment.
#
# Cascade strategy:
#   1. Clay (primary — waterfalls 50+ providers, verifies emails)
#   2. Claude + web search (fills gaps, validates, finds what Clay misses)
#   3. Secretary of State registered agent (fallback for LLCs with no web presence)
#
# Outputs a confidence score so the pipeline can decide whether to send immediately,
# flag for manual review, or skip.
class SmartEnrichmentService
  MODEL = :"claude-opus-4-6"

  MIN_CONFIDENCE_TO_SEND = 0.5  # Skip outreach below this threshold

  Result = Struct.new(
    :human_owner_name, :owner_title, :owner_email, :owner_phone,
    :owner_linkedin, :parent_company, :org_domain,
    :enrichment_source, :confidence, :notes,
    keyword_init: true
  )

  # Returns a Result struct. Always returns something — never raises.
  def self.enrich(owner_entity:, address: nil, state: nil)
    result = {}
    sources_used = []

    # --- Step 1: Apollo (primary — people search across 275M+ contacts with email verification) ---
    apollo_data = ApolloService.enrich(owner_entity: owner_entity)
    if apollo_data
      result.merge!(apollo_data)
      sources_used << 'apollo'
      Rails.logger.info "Enrichment: Apollo found #{apollo_data[:human_owner_name]} for #{owner_entity}"
    end

    # --- Step 2: Claude web search (always runs — fills gaps and validates Apollo) ---
    web_data = claude_web_enrich(
      owner_entity: owner_entity,
      address:      address,
      state:        state,
      existing:     result
    )

    if web_data
      # Prefer Claude data for fields Apollo missed or returned weak values for
      %i[human_owner_name owner_title owner_email owner_phone owner_linkedin
         parent_company org_domain].each do |field|
        result[field] = web_data[field] if web_data[field].present? && result[field].blank?
      end
      sources_used << 'web_search'
    end

    # --- Step 3: Secretary of State fallback for email ---
    if result[:owner_email].blank? && state
      sos_data = secretary_of_state_lookup(owner_entity: owner_entity, state: state)
      if sos_data
        result.merge!(sos_data)
        sources_used << 'secretary_of_state'
      end
    end

    confidence = calculate_confidence(result)
    notes      = build_notes(result, confidence, sources_used)

    Result.new(
      human_owner_name: result[:human_owner_name],
      owner_title:      result[:owner_title],
      owner_email:      result[:owner_email],
      owner_phone:      result[:owner_phone],
      owner_linkedin:   result[:owner_linkedin],
      parent_company:   result[:parent_company],
      org_domain:       result[:org_domain],
      enrichment_source: sources_used.join('+'),
      confidence:       confidence,
      notes:            notes
    )
  rescue StandardError => e
    Rails.logger.error "SmartEnrichment failed for #{owner_entity}: #{e.message}"
    Result.new(enrichment_source: 'failed', confidence: 0.0, notes: e.message)
  end

  private

  # Claude with web search — finds, validates, and cross-references contact info
  WEB_SEARCH_TIMEOUT = 120 # seconds — web search can do multiple rounds

  def self.claude_web_enrich(owner_entity:, address:, state:, existing:)
    client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

    existing_summary = existing.reject { |_, v| v.blank? }
      .map { |k, v| "#{k}: #{v}" }.join("\n")

    prompt = <<~PROMPT
      Find accurate contact information for the decision-maker at this commercial property company:

      Company: #{owner_entity}
      #{address ? "Property Address: #{address}" : ''}
      #{state ? "State: #{state}" : ''}

      #{existing_summary.present? ? "We already have this data (validate/supplement it):\n#{existing_summary}" : ''}

      Search for:
      1. The CEO, Managing Member, President, or principal owner — their full name and title
      2. Their direct email or the company's contact email
      3. Their LinkedIn URL
      4. The company's website domain
      5. Any parent company or investment group

      Use web search to verify. Cross-check Secretary of State records if it's an LLC.
      Return ONLY a JSON object with keys: human_owner_name, owner_title, owner_email,
      owner_phone, owner_linkedin, parent_company, org_domain.
      Use null for any field you cannot verify with reasonable confidence.
    PROMPT

    message = Timeout.timeout(WEB_SEARCH_TIMEOUT) do
      client.messages.create(
        model: MODEL,
        max_tokens: 4096,
        tools: [
          { type: 'web_search_20260209', name: 'web_search' }
        ],
        system: 'You are a B2B contact researcher. Find verified contact information for commercial real estate decision-makers. Return only confirmed facts as JSON.',
        messages: [{ role: 'user', content: prompt }]
      )
    end

    text = message.content.select { |b| b.type == 'text' }.map(&:text).join
    json_match = text.match(/\{[\s\S]*?\}/)
    return nil unless json_match

    JSON.parse(json_match[0], symbolize_names: true)
      .transform_values { |v| v.presence }
  rescue Timeout::Error
    Rails.logger.warn "Claude web enrichment timed out after #{WEB_SEARCH_TIMEOUT}s for #{owner_entity}"
    nil
  rescue StandardError => e
    Rails.logger.error "Claude web enrichment failed: #{e.message}"
    nil
  end

  SOS_TIMEOUT = 60 # seconds

  # Quick lookup using Claude + web search targeting state SOS databases
  def self.secretary_of_state_lookup(owner_entity:, state:)
    client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

    message = Timeout.timeout(SOS_TIMEOUT) do
      client.messages.create(
        model: MODEL,
        max_tokens: 1024,
        tools: [{ type: 'web_search_20260209', name: 'web_search' }],
        system: 'You look up registered agent and principal information from state Secretary of State records.',
        messages: [{
          role: 'user',
          content: "Search the #{state} Secretary of State database for the registered agent or principal of '#{owner_entity}'. Return a JSON object with: human_owner_name, owner_title, owner_email (if available), owner_phone (if available). Use null for unknown fields."
        }]
      )
    end

    text = message.content.select { |b| b.type == 'text' }.map(&:text).join
    json_match = text.match(/\{[\s\S]*?\}/)
    return nil unless json_match

    JSON.parse(json_match[0], symbolize_names: true).transform_values(&:presence)
  rescue Timeout::Error
    Rails.logger.warn "SoS lookup timed out after #{SOS_TIMEOUT}s for #{owner_entity}"
    nil
  rescue StandardError
    nil
  end

  # Confidence score 0.0–1.0 based on how much usable data we found
  def self.calculate_confidence(data)
    weights = {
      owner_email:      0.40,  # email is required for outreach
      human_owner_name: 0.25,
      owner_phone:      0.15,
      owner_title:      0.10,
      org_domain:       0.05,
      owner_linkedin:   0.05
    }
    weights.sum { |field, weight| data[field].present? ? weight : 0 }
  end

  def self.build_notes(data, confidence, sources)
    issues = []
    issues << 'No email found — LinkedIn/phone outreach only' if data[:owner_email].blank?
    issues << 'No owner name found' if data[:human_owner_name].blank?
    issues << 'Low confidence — manual review recommended' if confidence < MIN_CONFIDENCE_TO_SEND
    "Sources: #{sources.join(', ')}. #{issues.join('. ')}"
  end
end

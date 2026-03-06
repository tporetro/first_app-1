require 'anthropic'

# Intelligent multi-source contact enrichment.
#
# Cascade strategy:
#   0. Corporation Wiki (free — officer name + title from public records, no API key)
#   1. People Data Labs (person search by company name — name, email, phone, LinkedIn)
#   2. Claude + web search (finds domain, validates, supplements above)
#   3. Clay (enriches with verified email/phone/LinkedIn using domain from web search)
#   4. Secretary of State registered agent (fallback for LLCs with no web presence)
#
# Outputs a confidence score so the pipeline can decide whether to send immediately,
# flag for manual review, or skip.
class SmartEnrichmentService
  MODEL            = :"claude-haiku-4-5-20251001"  # cheap — used for non-search tasks
  WEB_SEARCH_MODEL = :"claude-sonnet-4-6"          # required for web_search_20260209 tool

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

    # --- Step 0a: Corporation Wiki (free — officer name + title, no API key) ---
    cw_data = CorporationWikiService.lookup(owner_entity: owner_entity, state: state)
    if cw_data
      result[:human_owner_name] = cw_data.human_owner_name if cw_data.human_owner_name.present?
      result[:owner_title]      = cw_data.owner_title      if cw_data.owner_title.present?
      sources_used << 'corporation_wiki'
      Rails.logger.info "Enrichment: Corporation Wiki found #{cw_data.human_owner_name} for #{owner_entity}"
    end

    # --- Step 1: People Data Labs (person search by company name) ---
    pdl_data = PeopleDataLabsService.enrich(owner_entity: owner_entity, state: state)
    if pdl_data
      result[:human_owner_name] = pdl_data.human_owner_name if pdl_data.human_owner_name.present?
      result[:owner_title]      = pdl_data.owner_title      if pdl_data.owner_title.present? && result[:owner_title].blank?
      result[:owner_email]      = pdl_data.owner_email      if pdl_data.owner_email.present?
      result[:owner_phone]      = pdl_data.owner_phone      if pdl_data.owner_phone.present?
      result[:owner_linkedin]   = pdl_data.owner_linkedin   if pdl_data.owner_linkedin.present?
      result[:org_domain]       = pdl_data.org_domain       if pdl_data.org_domain.present?
      sources_used << 'people_data_labs'
      Rails.logger.info "Enrichment: PDL found #{pdl_data.human_owner_name} / #{pdl_data.owner_email} for #{owner_entity}"
    end

    # --- Step 2: Claude web search (primary — finds domain, owner name, validates) ---
    web_data = claude_web_enrich(
      owner_entity: owner_entity,
      address:      address,
      state:        state,
      existing:     result
    )

    if web_data
      result.merge!(web_data.reject { |_, v| v.blank? })
      sources_used << 'web_search'
      Rails.logger.info "Enrichment: web search found #{web_data[:human_owner_name]} / #{web_data[:org_domain]} for #{owner_entity}"
    end

    # --- Step 2: Clay (verifies email/phone/LinkedIn, uses domain from web search) ---
    clay_data = ClayEnrichmentService.enrich(
      owner_entity: owner_entity,
      address:      address,
      state:        state,
      domain:       result[:org_domain]
    )
    if clay_data
      %i[human_owner_name owner_title owner_email owner_phone owner_linkedin
         parent_company org_domain].each do |field|
        result[field] = clay_data[field] if clay_data[field].present? && result[field].blank?
      end
      sources_used << 'clay'
      Rails.logger.info "Enrichment: Clay supplemented #{clay_data.keys.select { |k| clay_data[k].present? }.join(', ')} for #{owner_entity}"
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
  WEB_SEARCH_TIMEOUT = 600 # seconds — Sonnet web search can take 5+ minutes with many search rounds

  def self.claude_web_enrich(owner_entity:, address:, state:, existing:)
    client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

    existing_summary = existing.reject { |_, v| v.blank? }
      .map { |k, v| "#{k}: #{v}" }.join("\n")

    prompt = <<~PROMPT
      Find the specific person authorized to file or approve an insurance claim for this commercial property:

      Company: #{owner_entity}
      #{address ? "Property Address: #{address}" : ''}
      #{state ? "State: #{state}" : ''}

      #{existing_summary.present? ? "We already have this data (validate/supplement it):\n#{existing_summary}" : ''}

      We need the person who legally controls this property and can authorize an insurance claim —
      typically the Managing Member, Owner, President, CEO, Asset Manager, or Risk Manager.
      Do NOT return a leasing agent, broker, or tenant.

      Search for:
      1. Their full name and exact title
      2. Their direct email or the company's contact email
      3. Their direct phone number
      4. Their LinkedIn URL
      5. The company's website domain
      6. Any parent company or investment group that may own the property

      Use web search to verify. Cross-check Secretary of State registered agent records if it's an LLC.
      Return ONLY a JSON object with keys: human_owner_name, owner_title, owner_email,
      owner_phone, owner_linkedin, parent_company, org_domain.
      Use null for any field you cannot verify with reasonable confidence.
    PROMPT

    text = Timeout.timeout(WEB_SEARCH_TIMEOUT) do
      run_web_search_to_text(client, prompt)
    end

    return nil if text.blank?

    json_match = text.match(/\{[\s\S]*\}/)
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

  SOS_TIMEOUT = 600 # seconds

  # Quick lookup using Claude + web search targeting state SOS databases
  def self.secretary_of_state_lookup(owner_entity:, state:)
    client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])
    prompt = "Search the #{state} Secretary of State database for the registered agent or principal of '#{owner_entity}'. Return a JSON object with: human_owner_name, owner_title, owner_email (if available), owner_phone (if available). Use null for unknown fields."

    text = Timeout.timeout(SOS_TIMEOUT) do
      run_web_search_to_text(client, prompt,
        system: 'You look up registered agent and principal information from state Secretary of State records.')
    end

    return nil if text.blank?

    json_match = text.match(/\{[\s\S]*\}/)
    return nil unless json_match

    JSON.parse(json_match[0], symbolize_names: true).transform_values(&:presence)
  rescue Timeout::Error
    Rails.logger.warn "SoS lookup timed out after #{SOS_TIMEOUT}s for #{owner_entity}"
    nil
  rescue StandardError
    nil
  end

  # Executes a single web search request and extracts the text response.
  # web_search_20260209 is server-side: Anthropic runs all searches in one
  # call and returns end_turn with text as the last content block.
  def self.run_web_search_to_text(client, user_prompt, system: 'You are a B2B contact researcher. Find verified contact information for commercial real estate decision-makers. Return only confirmed facts as JSON.')
    resp = client.messages.create(
      model:      WEB_SEARCH_MODEL,
      max_tokens: 4096,
      tools:      [{ type: 'web_search_20260209', name: 'web_search' }],
      system:     system,
      messages:   [{ role: 'user', content: user_prompt }]
    )

    resp.content.select { |b| b.type == 'text' }.map(&:text).join.presence
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

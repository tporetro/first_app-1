# Intelligent multi-source contact enrichment.
#
# Cascade strategy:
#   0. Corporation Wiki (free — officer name + title from public records, no API key)
#   1. People Data Labs (person search by company name — name, email, phone, LinkedIn)
#   2. Clay (enriches with verified email/phone/LinkedIn using domain)
#
# Outputs a confidence score so the pipeline can decide whether to send immediately,
# flag for manual review, or skip.
class SmartEnrichmentService
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

    # --- Step 0: Corporation Wiki (free — officer name + title, no API key) ---
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

    # --- Step 2: Clay (verifies email/phone/LinkedIn) ---
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

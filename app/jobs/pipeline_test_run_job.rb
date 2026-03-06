class PipelineTestRunJob
  include Sidekiq::Job
  sidekiq_options queue: 'pipeline'

  def perform(test_email)
    log "=== Pipeline Test Run Started → #{test_email} ==="

    # 1. Seed test storm
    storm = StormEvent.create!(
      name:       "TEST Dallas #{Date.today.strftime('%Y-%m-%d')}",
      event_date: Date.yesterday,
      hail_size:  2.0,
      counties:   "Dallas",
      state:      "TX",
      metro_area: "Dallas",
      status:     "detected",
      notes:      "TEST RUN — created by PipelineTestRunJob. Safe to delete."
    )
    log "Storm created: #{storm.name} (id=#{storm.id})"

    # 2. Seed 1 real commercial property
    property = storm.properties.create!(
      address:       "6100 LBJ Freeway",
      city:          "Dallas",
      state:         "TX",
      county:        "Dallas",
      property_type: "Office",
      sq_ft:         87_500,
      roof_system:   "EPDM Membrane",
      owner_entity:  "LBJ Office Partners LLC",
      source:        "test",
      status:        "identified"
    )
    log "Property seeded: #{property.address}"
    PushoverService.notify(title: "🧪 Test Run Started", message: "Storm + property seeded. Running enrichment...")

    # 3. Enrich contact (real enrichment, email overridden to test address)
    log "Phase 3: Enriching #{property.owner_entity}..."
    result = SmartEnrichmentService.enrich(
      owner_entity: property.owner_entity,
      address:      property.address,
      state:        property.state
    )
    log "Enriched: #{result.human_owner_name} | #{(result.confidence * 100).round}% confidence | #{result.enrichment_source}"

    contact = storm.contacts.create!(
      owner_entity:      property.owner_entity,
      human_owner_name:  result.human_owner_name || "Test Owner",
      owner_title:       result.owner_title,
      owner_email:       test_email,
      owner_phone:       result.owner_phone,
      owner_linkedin:    result.owner_linkedin,
      parent_company:    result.parent_company,
      org_domain:        result.org_domain,
      enrichment_source: result.enrichment_source,
      status:            "enriched"
    )
    log "Contact saved (email → #{test_email})"
    PushoverService.notify(
      title: "✅ Phase 3 Done",
      message: "#{result.human_owner_name} | #{(result.confidence * 100).round}% confidence"
    )

    # 4. Generate Gamma report
    log "Phase 4: Generating Gamma report..."
    properties  = [property]
    contacts    = [contact]
    report_data = StormPipelineService.phase_4_generate_reports(storm, properties, contacts)
    log "Phase 4: #{report_data[:property_reports].size} report(s) generated"
    PushoverService.notify(title: "✅ Phase 4 Done", message: "#{report_data[:property_reports].size} Gamma report(s) generated")

    # 5. Generate presentation script
    log "Phase 5: Generating presentation script..."
    scripts = StormPipelineService.phase_5_generate_scripts(storm, properties, contacts, report_data)
    log "Phase 5: #{scripts.size} script(s) generated"
    PushoverService.notify(title: "✅ Phase 5 Done", message: "#{scripts.size} script(s) ready")

    # 6. Send outreach email
    log "Phase 6: Sending outreach email to #{test_email}..."
    sent = StormPipelineService.phase_6_send_outreach(properties, contacts, report_data)
    log "Phase 6: #{sent} email(s) sent"
    PushoverService.notify(
      title: "✅ Test Run Complete",
      message: "#{sent} email(s) sent to #{test_email} | Storm id=#{storm.id}"
    )

    log "=== Test Run Finished ==="
  end

  private

  def log(msg)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    Rails.logger.info "[#{timestamp}] TestRun: #{msg}"
    puts "[#{timestamp}] #{msg}"
  end
end

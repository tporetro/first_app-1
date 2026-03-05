# Storm Lead Pipeline — Zero-Touch Orchestrator
#
# Usage:
#   StormPipelineService.run          # full pipeline: detect → enrich → report → email
#   StormPipelineService.run_followups  # Amy follow-up cadence (call daily)
#
# Phase map mirrors the skill spec:
#   1  Storm Detection    (NOAA SPC)
#   2  Property ID        (maps-of-meaning / manual CSV import)
#   3  Contact Enrichment (Apollo.io)
#   4  Report Generation  (Gamma API)
#   5  Email Outreach     (Resend + Amy CC)
class StormPipelineService
  # Follow-up days per Amy methodology: 3, 7, 14, 21
  FOLLOWUP_DAYS = [3, 7, 14, 21].freeze

  # ---------------------------------------------------------------------------
  # Entry point — run the full pipeline for any new storms found today.
  # ---------------------------------------------------------------------------
  def self.run
    log "=== Storm Lead Pipeline Started ==="

    storms = phase_1_detect_storms
    if storms.empty?
      log "Phase 1: No qualifying storms detected. Pipeline idle."
      PushoverService.notify(title: 'Clawbot Idle', message: 'No storms >= 1.5" detected today.')
      return
    end

    storms.each do |storm_data|
      storm = persist_storm(storm_data)
      next unless storm

      PushoverService.notify(
        title: '⛈️ Storm Detected',
        message: "#{storm_data[:hail_size]}\" hail in #{storm_data[:location]}. Starting pipeline."
      )

      properties = phase_2_load_properties(storm)
      log "Phase 2: #{properties.size} properties loaded for #{storm.name}"

      contacts   = phase_3_enrich_contacts(storm, properties)
      log "Phase 3: #{contacts.size} contacts enriched"

      reports    = phase_4_generate_reports(storm, properties)
      log "Phase 4: #{reports.size} Gamma reports generated"

      sent       = phase_5_send_outreach(properties, contacts, reports)
      log "Phase 5: #{sent} outreach emails sent"

      storm.update!(status: 'complete')
      PushoverService.notify(
        title: '✅ Pipeline Complete',
        message: "#{sent} emails sent for #{storm.name}"
      )
    end

    log "=== Pipeline Finished ==="
  end

  # ---------------------------------------------------------------------------
  # Amy follow-up cadence — call this daily (9 AM CST via rake task / cron).
  # ---------------------------------------------------------------------------
  def self.run_followups
    log "=== Amy Follow-Up Scheduler ==="

    FOLLOWUP_DAYS.each do |day|
      due = EmailOutreach
        .joins(:email_campaign)
        .where(followup_day: 0, status: 'sent')
        .where(
          "email_outreaches.sent_at <= ? AND email_outreaches.sent_at > ?",
          day.days.ago.beginning_of_day,
          day.days.ago.end_of_day
        )
        .where(email_campaigns: { replied_at: nil })

      due.each do |outreach|
        send_followup(outreach, day)
      end
    end

    log "=== Follow-Up Scheduler Complete ==="
  end

  # ---------------------------------------------------------------------------
  # Phases
  # ---------------------------------------------------------------------------

  def self.phase_1_detect_storms
    NoaaService.fetch_recent_hail(date: :yesterday)
  end

  def self.phase_2_load_properties(storm)
    # Returns existing Property records for this storm.
    # Properties are populated by the maps-of-meaning CSV import task
    # (rake pipeline:import_properties[storm_id,csv_path]).
    storm.properties.where(status: 'identified')
  end

  def self.phase_3_enrich_contacts(storm, properties)
    contacts = []
    properties.map(&:owner_entity).uniq.compact.each do |property_entity|
      # Skip if already enriched for this storm
      next if storm.contacts.exists?(owner_entity: property_entity)

      # Find matching property for state context
      prop = properties.find { |p| p.owner_entity == property_entity }

      # Clay-first enrichment with Claude web search fallback
      result = SmartEnrichmentService.enrich(
        owner_entity: property_entity,
        address:      prop&.address,
        state:        prop&.state
      )

      contact_status = result.confidence >= SmartEnrichmentService::MIN_CONFIDENCE_TO_SEND ? 'enriched' : 'low_confidence'
      contact = storm.contacts.create!(
        owner_entity:    property_entity,
        human_owner_name: result.human_owner_name,
        owner_title:     result.owner_title,
        owner_email:     result.owner_email,
        owner_phone:     result.owner_phone,
        owner_linkedin:  result.owner_linkedin,
        parent_company:  result.parent_company,
        org_domain:      result.org_domain,
        enrichment_source: result.enrichment_source,
        status:          contact_status
      )

      HubspotService.upsert_contact(lead: {
        owner_entity: property_entity, human_owner_name: result.human_owner_name,
        owner_title: result.owner_title, owner_email: result.owner_email,
        owner_phone: result.owner_phone, owner_linkedin: result.owner_linkedin,
        parent_company: result.parent_company, org_domain: result.org_domain
      })

      contacts << contact
      PushoverService.notify(
        title: 'Contact Enriched',
        message: "#{result.human_owner_name} (#{property_entity}) — #{(result.confidence * 100).round}% confidence"
      )
    end
    contacts
  end

  def self.phase_4_generate_reports(storm, properties)
    reports = []
    # 2-second delay between Gamma API submissions (rate limit)
    properties.each_with_index do |property, idx|
      sleep 2 if idx > 0

      markdown = ReportTemplateService.render(storm: storm, property: property)
      gamma_url = GammaReportService.generate(markdown_content: markdown)
      next unless gamma_url

      report = GammaReport.create!(
        property: property,
        report_id: "#{storm.id}-#{property.id}",
        gamma_url: gamma_url,
        status: 'completed',
        credits_used: 400
      )
      reports << report
    end
    reports
  end

  def self.phase_5_send_outreach(properties, contacts, reports)
    sent = 0
    properties.each do |property|
      contact = contacts.find { |c| c.owner_entity == property.owner_entity }
      report  = reports.find  { |r| r.property_id == property.id }
      next unless contact && report
      next if contact.owner_email.blank?  # flag for LinkedIn/phone manual outreach

      lead_data = build_lead_data(property, contact)

      # Thompson Sampling selects the best variant given current performance data
      variant = VariantOptimizerService.assign(storm_event_id: property.storm_event_id)

      # Research the prospect so Claude can write something genuinely personal
      research = ProspectResearchService.research(lead: lead_data)
      enriched_lead = lead_data.merge(research: research)

      # Claude writes the email — no templates, actual reasoning about this person
      composed = AiEmailComposerService.compose(
        lead:       enriched_lead,
        report_url: report.gamma_url,
        variant:    variant
      )

      # Send via Resend
      send_result = ResendEmailService.send_outreach(
        to:         contact.owner_email,
        lead:       enriched_lead.merge(composed.slice(:subject)),
        report_url: report.gamma_url,
        variant:    variant
      )

      # Override with AI-generated body by sending via Resend directly with composed content
      # (ResendEmailService.send_outreach handles the actual HTTP POST)

      outreach = EmailOutreach.create!(
        property:      property,
        contact:       contact,
        gamma_report:  report,
        subject:       composed[:subject],
        body:          composed[:body],
        sent_to_email: contact.owner_email,
        status:        send_result[:success] ? 'sent' : 'failed',
        sent_at:       send_result[:success] ? Time.now : nil,
        followup_day:  0,
        error_message: send_result[:error]
      )

      if send_result[:success]
        EmailCampaign.create!(
          email_outreach:    outreach,
          mailgun_message_id: send_result[:message_id],
          owner_name:        contact.human_owner_name,
          address:           property.address,
          variant:           variant,
          status:            'sent'
        )
        sent += 1
      end
    end
    sent
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def self.send_followup(original_outreach, day)
    contact = original_outreach.contact
    return unless contact&.owner_email

    lead_data = build_lead_data(original_outreach.property, contact)
    result = ResendEmailService.send_outreach(
      to:         contact.owner_email,
      lead:       lead_data.merge(followup_day: day),
      report_url: original_outreach.gamma_report&.gamma_url || '#',
      variant:    original_outreach.email_campaign&.variant || 'a'
    )

    EmailOutreach.create!(
      property:     original_outreach.property,
      contact:      contact,
      gamma_report: original_outreach.gamma_report,
      subject:      "Follow-up (Day #{day}): #{original_outreach.subject}",
      body:         '',
      sent_to_email: contact.owner_email,
      status:       result[:success] ? 'sent' : 'failed',
      sent_at:      result[:success] ? Time.now : nil,
      followup_day: day,
      error_message: result[:error]
    )

    log "Follow-up Day #{day} sent to #{contact.owner_email}" if result[:success]
  end

  def self.persist_storm(storm_data)
    StormEvent.create!(
      name:       "#{storm_data[:location]} #{storm_data[:date]}",
      event_date: storm_data[:date],
      hail_size:  storm_data[:hail_size],
      counties:   storm_data[:counties].join(', '),
      state:      storm_data[:state],
      metro_area: storm_data[:location],
      status:     'detected'
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to persist storm: #{e.message}"
    nil
  end

  def self.build_lead_data(property, contact)
    {
      address:         property.address,
      county:          property.county,
      hail_size:       property.storm_event.hail_size,
      storm_date:      property.storm_event.event_date.strftime('%B %-d, %Y'),
      owner_entity:    property.owner_entity,
      human_owner_name: contact.human_owner_name,
      owner_title:     contact.owner_title,
      owner_email:     contact.owner_email,
      owner_phone:     contact.owner_phone,
      parent_company:  contact.parent_company,
      org_domain:      contact.org_domain
    }
  end

  # Distribute properties across A/B/C/D variants for subject line testing
  def self.assign_variant(property_id)
    %w[a b c d][property_id % 4]
  end

  def self.log(msg)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    Rails.logger.info "[#{timestamp}] StormPipeline: #{msg}"
    puts "[#{timestamp}] #{msg}"
  end
end

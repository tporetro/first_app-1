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
      storm, newly_created = persist_storm(storm_data)
      next unless storm

      unless newly_created
        log "Storm already processed: #{storm.name} (id=#{storm.id}) — skipping"
        next
      end

      PushoverService.notify(
        title: '⛈️ Storm Detected',
        message: "#{storm_data[:hail_size]}\" hail in #{storm_data[:location]}. Starting pipeline."
      )

      begin
        properties = phase_2_load_properties(storm)
        log "Phase 2: #{properties.size} properties loaded for #{storm.name}"

        contacts   = phase_3_enrich_contacts(storm, properties)
        log "Phase 3: #{contacts.size} contacts enriched"

        report_data = phase_4_generate_reports(storm, properties, contacts)
        prop_count  = report_data[:property_reports].size
        port_count  = report_data[:portfolio_reports].size
        log "Phase 4: #{prop_count} property reports + #{port_count} portfolio overviews generated"

        scripts    = phase_5_generate_scripts(storm, properties, contacts, report_data)
        log "Phase 5: #{scripts.size} presentation scripts generated"

        sent       = phase_6_send_outreach(properties, contacts, report_data)
        log "Phase 6: #{sent} outreach emails sent"

        storm.update!(status: 'complete')
        PushoverService.notify(
          title: '✅ Pipeline Complete',
          message: "#{sent} emails sent for #{storm.name}"
        )
      rescue StandardError => e
        error_msg = "#{e.class}: #{e.message}"
        log "ERROR processing #{storm.name}: #{error_msg}"
        storm.update(status: 'error')
        PushoverService.notify(
          title: '❌ Pipeline Error',
          message: "#{storm.name} failed — #{error_msg.truncate(200)}"
        )
      end
    end

    log "=== Pipeline Finished ==="
  end

  # ---------------------------------------------------------------------------
  # Amy follow-up cadence — call this daily (9 AM CST via rake task / cron).
  # ---------------------------------------------------------------------------
  def self.run_followups
    log "=== Amy Follow-Up Scheduler ==="

    FOLLOWUP_DAYS.each do |day|
      # Find initial outreaches (followup_day: 0) sent exactly `day` days ago,
      # where no reply has been received on any follow-up in the thread.
      due = EmailOutreach
        .joins(:email_campaign)
        .where(followup_day: 0, status: 'sent')
        .where(
          "email_outreaches.sent_at >= ? AND email_outreaches.sent_at <= ?",
          day.days.ago.beginning_of_day,
          day.days.ago.end_of_day
        )
        .where(email_campaigns: { replied_at: nil })

      due.each do |outreach|
        # Skip if already sent this follow-up day for this outreach thread
        already_sent = EmailOutreach.where(
          property:     outreach.property,
          contact:      outreach.contact,
          followup_day: day
        ).exists?
        next if already_sent

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
    # Auto-discover commercial properties via CAD scraping + Claude Vision boundary analysis.
    # Falls back to any manually-imported properties if CAD returns nothing.
    auto_count = MapsOfMeaningService.run(storm)
    log "Phase 2 (MapsOfMeaning): #{auto_count} properties auto-imported from CAD" if auto_count > 0

    storm.properties.reload.where(status: 'identified')
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

  # Phase 4: Generate reports in correct order:
  #   1. Individual property reports (need their URLs first)
  #   2. Portfolio overview (embeds individual report URLs, for multi-property owners)
  #
  # Returns: { property_reports: [...GammaReport], portfolio_reports: { owner_entity => GammaReport } }
  def self.phase_4_generate_reports(storm, properties, contacts)
    property_reports  = []
    portfolio_reports = {}  # owner_entity => GammaReport (portfolio overview)

    # Step 4a: Individual property technical reports
    properties.each_with_index do |property, idx|
      sleep 2 if idx > 0

      markdown  = ReportTemplateService.render_property(storm: storm, property: property)
      gamma_url = GammaReportService.generate(markdown_content: markdown)
      next unless gamma_url

      report = GammaReport.create!(
        property:   property,
        report_id:  "prop-#{storm.id}-#{property.id}",
        gamma_url:  gamma_url,
        status:     'completed',
        credits_used: 400
      )
      property_reports << report
    end

    # Step 4b: Portfolio overview for owners with 2+ properties
    # Groups properties by owner_entity, generates one portfolio deck per owner
    by_owner = properties.group_by(&:owner_entity)
    by_owner.each do |entity, owner_properties|
      next if owner_properties.size < 2  # single-property owners get just the property report

      sleep 2

      contact = contacts.find { |c| c.owner_entity == entity }
      property_report_urls = owner_properties.each_with_object({}) do |p, h|
        report = property_reports.find { |r| r.property_id == p.id }
        h[p.id] = report.gamma_url if report
      end

      markdown = ReportTemplateService.render_portfolio(
        storm:               storm,
        properties:          owner_properties,
        owner_entity:        entity,
        contact:             contact,
        property_report_urls: property_report_urls
      )

      gamma_url = GammaReportService.generate(markdown_content: markdown)
      next unless gamma_url

      # Use first property as anchor for the portfolio report record
      anchor_property = owner_properties.first
      portfolio_report = GammaReport.create!(
        property:   anchor_property,
        report_id:  "portfolio-#{storm.id}-#{entity.parameterize}",
        gamma_url:  gamma_url,
        status:     'completed',
        credits_used: 400
      )
      portfolio_reports[entity] = portfolio_report

      log "Portfolio overview generated for #{entity} (#{owner_properties.size} properties)"
    end

    { property_reports: property_reports, portfolio_reports: portfolio_reports }
  end

  # Phase 5: Generate personalized presentation scripts for each owner.
  # Scripts are written to tmp/presentation_scripts/ as Markdown files and
  # returned as an array of hashes: [{ owner_entity:, path:, markdown: }, ...]
  def self.phase_5_generate_scripts(storm, properties, contacts, report_data)
    property_reports  = report_data[:property_reports]
    portfolio_reports = report_data[:portfolio_reports]
    scripts           = []
    scripts_dir       = Rails.root.join('tmp', 'presentation_scripts', storm.id.to_s)
    FileUtils.mkdir_p(scripts_dir)

    by_owner = properties.group_by(&:owner_entity)

    by_owner.each do |entity, owner_properties|
      contact = contacts.find { |c| c.owner_entity == entity }
      next unless contact

      primary_report = portfolio_reports[entity] ||
                       property_reports.find { |r| r.property_id == owner_properties.first.id }
      report_url = primary_report&.gamma_url || '#'

      result = PresentationScriptService.generate(
        storm:      storm,
        properties: owner_properties,
        contact:    contact,
        report_url: report_url
      )
      next unless result

      filename = "#{entity.parameterize}_script.md"
      path     = scripts_dir.join(filename)
      File.write(path, result[:markdown])

      scripts << { owner_entity: entity, path: path.to_s, markdown: result[:markdown] }
      log "Presentation script saved: #{filename}"
    end

    scripts
  end

  def self.phase_6_send_outreach(properties, contacts, report_data, dry_run: false)
    property_reports  = report_data[:property_reports]
    portfolio_reports = report_data[:portfolio_reports]
    sent = 0

    # Group properties by owner — one email per owner (covers all their properties)
    by_owner = properties.group_by(&:owner_entity)

    by_owner.each do |entity, owner_properties|
      contact = contacts.find { |c| c.owner_entity == entity }
      next unless contact
      next if contact.owner_email.blank?

      # Determine which report to link in the email:
      # Multi-property → portfolio overview; single → property report
      primary_report = if portfolio_reports[entity]
                         portfolio_reports[entity]
                       else
                         property_reports.find { |r| r.property_id == owner_properties.first.id }
                       end
      next unless primary_report

      lead_data = build_portfolio_lead_data(storm: owner_properties.first.storm_event,
                                             properties: owner_properties,
                                             contact: contact)

      variant = VariantOptimizerService.assign(storm_event_id: owner_properties.first.storm_event_id)

      # Claude researches the owner and writes a genuinely personalized email
      research     = ProspectResearchService.research(lead: lead_data)
      enriched_lead = lead_data.merge(research: research)

      composed = AiEmailComposerService.compose(
        lead:       enriched_lead,
        report_url: primary_report.gamma_url,
        variant:    variant
      )

      if dry_run
        log "[DRY RUN] Would send to: #{contact.owner_email}"
        log "[DRY RUN] Subject: #{composed[:subject]}"
        log "[DRY RUN] Report: #{primary_report.gamma_url}"
        log "[DRY RUN] Variant: #{variant}"
        log "[DRY RUN] Body preview: #{composed[:body]&.truncate(300)}"
        sent += 1
        next
      end

      send_result = ResendEmailService.send_composed(
        to:      contact.owner_email,
        subject: composed[:subject],
        body_html: composed[:body_html] || nil,
        body_text: composed[:body]
      )

      # Record one outreach per owner (anchor to first property)
      anchor = owner_properties.first
      outreach = EmailOutreach.create!(
        property:      anchor,
        contact:       contact,
        gamma_report:  primary_report,
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
          email_outreach:     outreach,
          mailgun_message_id: send_result[:message_id],
          owner_name:         contact.human_owner_name,
          address:            anchor.address,
          variant:            variant,
          status:             'sent'
        )
        sent += 1
        PushoverService.notify(
          title: 'Email Sent',
          message: "#{contact.human_owner_name} — #{owner_properties.size} #{owner_properties.size == 1 ? 'property' : 'properties'}, #{lead_data[:total_recovery]}"
        )
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

    report_url = original_outreach.gamma_report&.gamma_url || '#'
    variant    = original_outreach.email_campaign&.variant || 'a'
    campaign   = original_outreach.email_campaign

    # Build engagement context so Claude can reason about what to write
    prior_followups = EmailOutreach.where(
      property:     original_outreach.property,
      contact:      contact,
      followup_day: 1..20
    ).count

    engagement = {
      opened:          campaign&.opened_at.present?,
      clicked:         campaign&.clicked_at.present?,
      open_count:      campaign&.opened_at.present? ? 1 : 0,  # Resend basic tracking
      prior_followups: prior_followups
    }

    lead_data = build_portfolio_lead_data(
      storm:      original_outreach.property.storm_event,
      properties: contact.storm_event.properties.where(owner_entity: contact.owner_entity).to_a,
      contact:    contact
    )

    log "Follow-up Day #{day} — #{contact.owner_entity} | opened=#{engagement[:opened]} clicked=#{engagement[:clicked]}"

    # Claude composes an engagement-aware follow-up (different from the initial email)
    composed = AiEmailComposerService.compose_followup(
      lead:       lead_data,
      report_url: report_url,
      day:        day,
      engagement: engagement,
      variant:    variant
    )

    result = ResendEmailService.send_composed(
      to:        contact.owner_email,
      subject:   composed[:subject],
      body_text: composed[:body]
    )

    outreach = EmailOutreach.create!(
      property:      original_outreach.property,
      contact:       contact,
      gamma_report:  original_outreach.gamma_report,
      subject:       composed[:subject],
      body:          composed[:body],
      sent_to_email: contact.owner_email,
      status:        result[:success] ? 'sent' : 'failed',
      sent_at:       result[:success] ? Time.now : nil,
      followup_day:  day,
      error_message: result[:error]
    )

    if result[:success]
      EmailCampaign.create!(
        email_outreach:     outreach,
        mailgun_message_id: result[:message_id],
        owner_name:         contact.human_owner_name,
        address:            original_outreach.property.address,
        variant:            variant,
        status:             'sent'
      )

      engagement_label = engagement[:clicked] ? 'CLICKED' : engagement[:opened] ? 'opened' : 'no-open'
      PushoverService.notify(
        title: "Follow-up Day #{day} Sent",
        message: "#{contact.human_owner_name} (#{engagement_label}) — #{original_outreach.property.address}"
      )
      log "Follow-up Day #{day} sent to #{contact.owner_email} [#{engagement_label}]"
    else
      log "Follow-up Day #{day} FAILED for #{contact.owner_email}: #{result[:error]}"
    end
  end

  # Returns [storm, newly_created] so callers can skip re-processing existing storms.
  # Uniqueness key: event_date + state + metro_area.
  # The 15-min cron runs constantly — without this, the same storm triggers
  # duplicate outreach to every owner on every monitor cycle.
  def self.persist_storm(storm_data)
    name = "#{storm_data[:location]} #{storm_data[:date]}"

    storm = StormEvent.find_by(
      event_date: storm_data[:date],
      state:      storm_data[:state],
      metro_area: storm_data[:location]
    )

    if storm
      return [storm, false]
    end

    storm = StormEvent.create!(
      name:       name,
      event_date: storm_data[:date],
      hail_size:  storm_data[:hail_size],
      counties:   storm_data[:counties].join(', '),
      state:      storm_data[:state],
      metro_area: storm_data[:location],
      status:     'detected'
    )
    [storm, true]
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to persist storm: #{e.message}"
    [nil, false]
  end

  # Build lead data for multi-property portfolio outreach
  def self.build_portfolio_lead_data(storm:, properties:, contact:)
    total_recovery = properties.sum { |p| ((p.sq_ft || 0) * ReportTemplateService::COST_PER_SQFT).to_i }
    deadline = (storm.event_date >> ReportTemplateService::CLAIM_WINDOW_MONTHS).strftime('%B %-d, %Y')
    {
      address:          properties.first.address,
      city:             properties.first.city,
      state:            properties.first.state,
      county:           properties.map(&:county).uniq.join(', '),
      hail_size:        storm.hail_size,
      storm_date:       storm.event_date.strftime('%B %-d, %Y'),
      owner_entity:     contact.owner_entity,
      human_owner_name: contact.human_owner_name,
      owner_title:      contact.owner_title,
      owner_email:      contact.owner_email,
      owner_phone:      contact.owner_phone,
      parent_company:   contact.parent_company,
      org_domain:       contact.org_domain,
      property_count:   properties.size,
      total_recovery:   ReportTemplateService.fmt_dollars(total_recovery),
      claim_deadline:   deadline
    }
  end

  # Kept for single-property compatibility
  def self.build_lead_data(property, contact)
    build_portfolio_lead_data(
      storm:      property.storm_event,
      properties: [property],
      contact:    contact
    )
  end

  def self.log(msg)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    Rails.logger.info "[#{timestamp}] StormPipeline: #{msg}"
    puts "[#{timestamp}] #{msg}"
  end
end

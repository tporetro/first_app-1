namespace :pipeline do
  # ---------------------------------------------------------------------------
  # Storm detection + full pipeline run — cron every 15 minutes for first-mover
  # Crontab: */15 * * * * cd /app && bundle exec rake pipeline:monitor RAILS_ENV=production
  # ---------------------------------------------------------------------------
  desc 'Check for new hail storms and run full pipeline if found (run every 15 min)'
  task monitor: :environment do
    puts "[#{Time.now}] Clawbot: Checking NOAA SPC for storms..."
    StormPipelineService.run
  end

  # ---------------------------------------------------------------------------
  # Amy follow-up cadence — run once daily at 9 AM CST
  # Crontab: 0 15 * * * cd /app && bundle exec rake pipeline:followups RAILS_ENV=production
  # ---------------------------------------------------------------------------
  desc 'Send Amy follow-up emails (day 3, 7, 14, 21) — run daily at 9 AM CST'
  task followups: :environment do
    puts "[#{Time.now}] Amy: Running follow-up cadence..."
    StormPipelineService.run_followups
  end

  # ---------------------------------------------------------------------------
  # Mark 48h-old sends with no open as failures for variant optimizer
  # Crontab: 0 * * * * cd /app && bundle exec rake pipeline:record_failures RAILS_ENV=production
  # ---------------------------------------------------------------------------
  desc 'Score unopened emails as variant failures for Thompson Sampling optimizer'
  task record_failures: :environment do
    cutoff = 48.hours.ago
    EmailCampaign
      .where(opened_at: nil, status: 'sent')
      .where('created_at < ?', cutoff)
      .each do |campaign|
        storm_id = campaign.email_outreach&.property&.storm_event_id
        VariantOptimizerService.record_failure(
          variant:        campaign.variant,
          storm_event_id: storm_id
        )
        campaign.update!(status: 'no_open')
      end
    puts "[#{Time.now}] Optimizer: failure scores updated"
  end

  # ---------------------------------------------------------------------------
  # Import properties from CSV (maps-of-meaning output — Phase 2)
  # Usage: rake pipeline:import_properties[1,/path/to/properties.csv]
  # ---------------------------------------------------------------------------
  desc 'Import property CSV for a storm event (rake pipeline:import_properties[storm_id,csv_path])'
  task :import_properties, [:storm_id, :csv_path] => :environment do |_, args|
    require 'csv'
    storm = StormEvent.find(args[:storm_id])
    csv   = CSV.read(args[:csv_path], headers: true)

    count = 0
    csv.each do |row|
      storm.properties.find_or_create_by!(address: row['address'], city: row['city'], state: row['state']) do |p|
        p.county        = row['county']
        p.property_type = row['property_type']
        p.sq_ft         = row['sq_ft']&.to_i
        p.owner_entity  = row['owner_entity']
        p.roof_system   = row['roof_system']
        p.status        = 'identified'
      end
      count += 1
    end

    puts "[#{Time.now}] Imported #{count} properties for storm #{storm.name}"
  end

  # ---------------------------------------------------------------------------
  # Run enrichment only (Phase 3) for a storm
  # ---------------------------------------------------------------------------
  desc 'Run contact enrichment for all properties in a storm (rake pipeline:enrich[storm_id])'
  task :enrich, [:storm_id] => :environment do |_, args|
    storm = StormEvent.find(args[:storm_id])
    storm.properties.where(status: 'identified').each do |property|
      next if storm.contacts.exists?(owner_entity: property.owner_entity)

      result = SmartEnrichmentService.enrich(
        owner_entity: property.owner_entity,
        address:      property.address,
        state:        property.state
      )

      storm.contacts.create!(
        owner_entity:    property.owner_entity,
        human_owner_name: result.human_owner_name,
        owner_title:     result.owner_title,
        owner_email:     result.owner_email,
        owner_phone:     result.owner_phone,
        owner_linkedin:  result.owner_linkedin,
        parent_company:  result.parent_company,
        org_domain:      result.org_domain,
        enrichment_source: result.enrichment_source,
        status:          result.confidence >= SmartEnrichmentService::MIN_CONFIDENCE_TO_SEND ? 'enriched' : 'low_confidence'
      )

      puts "Enriched: #{property.owner_entity} (confidence: #{(result.confidence * 100).round}%)"
    end
  end

  # ---------------------------------------------------------------------------
  # Manually seed a known storm event (bypass NOAA — use when storm is confirmed
  # in the field before API data is available).
  # Usage: rake pipeline:seed_storm[1.5,"Dallas",TX,"Dallas,Collin,Denton",2026-03-05]
  # Counties: comma-separated, no spaces around commas
  # ---------------------------------------------------------------------------
  desc 'Seed a manually confirmed storm event (rake pipeline:seed_storm[hail_size,metro,state,counties,date])'
  task :seed_storm, [:hail_size, :metro, :state, :counties, :date] => :environment do |_, args|
    hail_size = args[:hail_size].to_f
    metro     = args[:metro]
    state     = args[:state]
    counties  = args[:counties]
    date      = args[:date] ? Date.parse(args[:date]) : Date.today

    if hail_size < 1.5
      puts "ERROR: Hail size #{hail_size}\" is below the 1.5\" qualifying threshold. Aborting."
      next
    end

    name = "#{metro} #{date.strftime('%Y-%m-%d')}"

    if StormEvent.exists?(name: name)
      storm = StormEvent.find_by(name: name)
      puts "Storm already exists: #{storm.name} (id=#{storm.id})"
    else
      storm = StormEvent.create!(
        name:       name,
        event_date: date,
        hail_size:  hail_size,
        counties:   counties,
        state:      state,
        metro_area: metro,
        status:     'detected',
        notes:      "Manually seeded — field confirmation #{Time.now.strftime('%Y-%m-%d %H:%M')} CST"
      )
      puts "Storm created: #{storm.name} (id=#{storm.id})"
    end

    puts ""
    puts "Next steps:"
    puts "  1. Export commercial properties in the hail swath from maps-of-meaning / county CAD"
    puts "  2. rake pipeline:import_properties[#{storm.id},/path/to/properties.csv]"
    puts "  3. rake pipeline:enrich[#{storm.id}]"
    puts "  4. (pipeline:monitor will generate reports and send outreach on next cron run)"
  end

  # ---------------------------------------------------------------------------
  # Demo: wipe and re-seed Dallas demo data
  # Usage: rake demo:seed_dallas
  # ---------------------------------------------------------------------------
end

namespace :demo do
  desc 'Wipe all data and reseed with Dallas demo storm data (for presentations)'
  task seed_dallas: :environment do
    puts "Wiping existing data..."
    EmailCampaign.delete_all
    EmailOutreach.delete_all
    GammaReport.delete_all
    Contact.delete_all
    Property.delete_all
    StormEvent.delete_all
    puts "Running Dallas seed..."
    load Rails.root.join('db', 'seeds.rb')
  end
end

namespace :pipeline do
  # ---------------------------------------------------------------------------
  # End-to-end test run — real enrichment, real Gamma report, email to you
  # Usage: rake pipeline:test_run[you@example.com]
  # ---------------------------------------------------------------------------
  desc 'Full pipeline test: seeds a storm+property, runs enrichment→report→email to TEST_EMAIL'
  task :test_run, [:test_email] => :environment do |_, args|
    test_email = args[:test_email]
    unless test_email
      puts "ERROR: Provide a test email: rake pipeline:test_run[you@example.com]"
      next
    end

    puts "[TEST] Starting end-to-end pipeline test"
    puts "[TEST] Outreach email will be routed to: #{test_email}"
    puts ""

    # 1. Seed a test storm
    storm = StormEvent.create!(
      name:       "TEST Dallas #{Date.today.strftime('%Y-%m-%d')}",
      event_date: Date.yesterday,
      hail_size:  2.0,
      counties:   "Dallas",
      state:      "TX",
      metro_area: "Dallas",
      status:     "detected",
      notes:      "TEST RUN — created by pipeline:test_run. Safe to delete."
    )
    puts "[TEST] Storm created: #{storm.name} (id=#{storm.id})"

    # 2. Seed 1 real commercial property (identified, ready for enrichment)
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
    puts "[TEST] Property seeded: #{property.address} (#{property.owner_entity})"
    PushoverService.notify(title: "🧪 Test Run Started", message: "Storm + property seeded. Running Phase 3 enrichment...")

    # 3. Enrich contact (real Clay + Claude enrichment)
    puts ""
    puts "[TEST] Phase 3: Enriching #{property.owner_entity}..."
    result = SmartEnrichmentService.enrich(
      owner_entity: property.owner_entity,
      address:      property.address,
      state:        property.state
    )
    puts "[TEST] Enriched: #{result.human_owner_name} | confidence #{(result.confidence * 100).round}% | source: #{result.enrichment_source}"

    contact = storm.contacts.create!(
      owner_entity:      property.owner_entity,
      human_owner_name:  result.human_owner_name || "Test Owner",
      owner_title:       result.owner_title,
      owner_email:       test_email,   # route to test inbox, not real owner
      owner_phone:       result.owner_phone,
      owner_linkedin:    result.owner_linkedin,
      parent_company:    result.parent_company,
      org_domain:        result.org_domain,
      enrichment_source: result.enrichment_source,
      status:            "enriched"
    )
    puts "[TEST] Contact saved (email overridden → #{test_email})"
    PushoverService.notify(
      title: "✅ Phase 3 Done",
      message: "#{result.human_owner_name} | #{(result.confidence * 100).round}% confidence | #{result.enrichment_source}"
    )

    # 4. Generate Gamma report
    puts ""
    puts "[TEST] Phase 4: Generating Gamma report..."
    properties  = [property]
    contacts    = [contact]
    report_data = StormPipelineService.phase_4_generate_reports(storm, properties, contacts)
    prop_count  = report_data[:property_reports].size
    puts "[TEST] #{prop_count} report(s) generated"
    PushoverService.notify(title: "✅ Phase 4 Done", message: "#{prop_count} Gamma report(s) generated")

    # 5. Generate presentation script
    puts ""
    puts "[TEST] Phase 5: Generating presentation script..."
    scripts = StormPipelineService.phase_5_generate_scripts(storm, properties, contacts, report_data)
    puts "[TEST] #{scripts.size} script(s) generated"
    PushoverService.notify(title: "✅ Phase 5 Done", message: "#{scripts.size} presentation script(s) ready")

    # 6. Send outreach email
    puts ""
    puts "[TEST] Phase 6: Sending outreach email to #{test_email}..."
    sent = StormPipelineService.phase_6_send_outreach(properties, contacts, report_data)
    puts "[TEST] #{sent} email(s) sent"
    PushoverService.notify(
      title: "✅ Test Run Complete",
      message: "#{sent} email(s) sent to #{test_email} | Storm id=#{storm.id}"
    )

    puts ""
    puts "[TEST] ✅ Done! Check your inbox: #{test_email}"
    puts "[TEST]    Dashboard: /pipeline/#{storm.id}"
    puts "[TEST]    To clean up: StormEvent.find(#{storm.id}).destroy"
  end

  # ---------------------------------------------------------------------------
  # Dry run — full pipeline without sending any email. Safe to run anytime.
  # Usage: rake pipeline:dry_run[storm_id]
  #        rake pipeline:dry_run              (uses most recent storm)
  #        SKIP_GAMMA=1 rake pipeline:dry_run (skip Gamma API — use placeholder URLs)
  # ---------------------------------------------------------------------------
  desc 'Run full pipeline (enrich → report → script → compose) but skip the send (dry run)'
  task :dry_run, [:storm_id] => :environment do |_, args|
    storm = args[:storm_id] ? StormEvent.find(args[:storm_id]) : StormEvent.order(created_at: :desc).first
    unless storm
      puts "ERROR: No storm found. Pass a storm_id or seed one first."
      next
    end

    skip_gamma = ENV['SKIP_GAMMA'].present?

    puts "[DRY RUN] Storm: #{storm.name} (id=#{storm.id})"
    puts "[DRY RUN] No emails will be sent."
    puts "[DRY RUN] Gamma: #{skip_gamma ? 'SKIPPED (placeholder URLs)' : 'enabled'}"
    puts ""

    properties = storm.properties.where(status: 'identified').to_a
    if properties.empty?
      puts "[DRY RUN] No identified properties for this storm. Import some first."
      next
    end
    puts "[DRY RUN] Properties: #{properties.size}"

    new_contacts = StormPipelineService.phase_3_enrich_contacts(storm, properties)
    # Merge with any contacts already enriched in a prior run
    existing_contacts = storm.contacts.to_a
    contacts = (new_contacts + existing_contacts).uniq(&:owner_entity)
    puts "[DRY RUN] Contacts enriched: #{new_contacts.size} new, #{existing_contacts.size - new_contacts.size} existing (#{contacts.size} total)"
    puts ""

    if skip_gamma
      # Build stub report_data so Phases 5+6 can run without real Gamma reports
      placeholder_url = 'https://gamma.app/docs/dry-run-placeholder'
      property_reports = properties.map do |prop|
        GammaReport.new(
          property:     prop,
          report_id:    "dry-run-#{prop.id}",
          gamma_url:    placeholder_url,
          status:       'completed',
          credits_used: 0
        )
      end
      report_data = { property_reports: property_reports, portfolio_reports: {} }
      puts "[DRY RUN] Reports generated: #{property_reports.size} property stubs (SKIP_GAMMA), 0 portfolio"
    else
      report_data = StormPipelineService.phase_4_generate_reports(storm, properties, contacts)
      puts "[DRY RUN] Reports generated: #{report_data[:property_reports].size} property, #{report_data[:portfolio_reports].size} portfolio"
    end

    scripts = StormPipelineService.phase_5_generate_scripts(storm, properties, contacts, report_data)
    puts "[DRY RUN] Scripts generated: #{scripts.size}"
    puts ""

    would_send = StormPipelineService.phase_6_send_outreach(properties, contacts, report_data, dry_run: true)
    puts ""
    puts "[DRY RUN] Done. Would have sent #{would_send} email(s). Nothing was actually sent."
  end

  # ---------------------------------------------------------------------------
  # Variant performance report
  # ---------------------------------------------------------------------------
  desc 'Print A/B/C/D variant performance for a storm (rake pipeline:variants[storm_id])'
  task :variants, [:storm_id] => :environment do |_, args|
    storm_id = args[:storm_id]&.to_i
    summary  = VariantOptimizerService.performance_summary(storm_event_id: storm_id)

    puts "\n=== Variant Performance (Storm #{storm_id || 'global'}) ===\n"
    puts format("%-8s %-10s %-8s %-10s %-10s", 'VARIANT', 'SENDS', 'SCORE', 'SUCCESS', 'FAILURE')
    summary.each do |v|
      puts format("%-8s %-10d %-8s %-10d %-10d",
        "#{v[:variant].upcase}", v[:sends], "#{v[:score]}%", v[:successes], v[:failures])
    end
    puts
  end
end

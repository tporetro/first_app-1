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

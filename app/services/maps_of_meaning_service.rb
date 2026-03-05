require 'anthropic'

# Phase 2 — Property Identification ("Maps of Meaning" workflow)
#
# Automates the full workflow described in the Restoration GC process doc:
#
#   Step 1: Analyze the hail swath map image (Claude Vision) to extract
#           the precise geographic boundary of the storm path.
#
#   Step 2: Query county appraisal districts (CAD) for bulk property data
#           covering the affected counties.
#
#   Step 3: Filter to commercial land use codes only. Optionally retain
#           government/church properties for targeted outreach variants.
#
#   Step 4: Clip results to the refined storm boundary (if vision analysis
#           produced a polygon; otherwise falls back to county-level).
#
#   Step 5: Import qualifying properties into the pipeline as Property records
#           with status 'identified', ready for Phase 3 enrichment.
#
# Usage:
#   count = MapsOfMeaningService.run(storm)
#   # Returns number of properties identified and imported.
#
class MapsOfMeaningService
  # Texas CAD state property category codes to INCLUDE for standard commercial outreach.
  # Source: Texas Property Tax Code / PTAD state category definitions.
  COMMERCIAL_STATE_CODES = %w[
    F1   # Real property — commercial
    F2   # Personal property — commercial
    L1   # Commercial business personal property
    L2   # Industrial / manufacturing personal property
    B1   # Multifamily residential (4+ units) — qualifies for commercial claims
    B2   # Multifamily
    B3   # Multifamily
    B4   # Multifamily
  ].freeze

  # Additional codes for government/church outreach (variants F and future church variant).
  # Kept separate so they can be targeted with the correct email variant.
  GOVERNMENT_CODES = %w[X1 X2 X3 X4].freeze  # Exempt — governmental
  CHURCH_CODES     = %w[X5 X6].freeze         # Exempt — religious

  # Minimum sq ft to qualify — filters out small outbuildings and kiosks.
  MIN_SQ_FT = 5_000

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------
  def self.run(storm)
    log "Maps of Meaning: starting property identification for #{storm.name}"

    # Step 1 — Analyze swath map image to refine boundary (if map is available)
    boundary = analyze_swath_map(storm)
    if boundary
      storm.update!(boundary_definition: boundary.to_json)
      log "Boundary refined via vision analysis: #{boundary[:description]}"
    else
      log "No swath map image available — using county-level boundary: #{storm.counties}"
    end

    # Step 2 — Fetch CAD data for each county in the storm
    counties = storm.counties.split(',').map(&:strip)
    all_records = []

    counties.each do |county|
      log "Fetching CAD data for #{county} County, #{storm.state}..."
      records = CadScraperService.fetch_commercial_properties(
        county: county,
        state:  storm.state
      )
      log "  #{records.size} commercial records retrieved from #{county} CAD"
      all_records.concat(records)
    end

    if all_records.empty?
      log "WARNING: No CAD records retrieved. Check CadScraperService configuration."
      PushoverService.notify(
        title: 'Maps of Meaning: No Records',
        message: "#{storm.name} — CAD fetch returned 0 records. Manual import may be needed."
      )
      return 0
    end

    # Step 3 — Filter to qualifying commercial properties
    commercial = all_records.select { |r| qualifies?(r) }
    log "#{commercial.size} properties pass commercial filter (min #{MIN_SQ_FT} sq ft)"

    # Step 4 — Clip to boundary polygon if available (county-level fallback already applied)
    if boundary&.dig(:polygon)
      pre_clip = commercial.size
      commercial = clip_to_boundary(commercial, boundary[:polygon])
      log "Boundary clip: #{pre_clip} → #{commercial.size} properties within storm swath"
    end

    # Step 5 — Import into pipeline as Property records
    imported = import_properties(storm, commercial)
    log "Maps of Meaning complete: #{imported} properties imported for #{storm.name}"

    PushoverService.notify(
      title: 'Phase 2 Complete',
      message: "#{storm.name} — #{imported} commercial properties identified and ready for enrichment."
    )

    imported
  end

  # ---------------------------------------------------------------------------
  # Step 1: Claude Vision — analyze hail swath map image
  # ---------------------------------------------------------------------------
  # Returns a boundary hash: { description:, polygon: [[lat,lon], ...], bbox: {...} }
  # or nil if no map is available or vision analysis fails.
  #
  def self.analyze_swath_map(storm)
    return nil unless storm.swath_map_path.present?

    image_path = storm.swath_map_path
    return nil unless File.exist?(image_path)

    log "Analyzing swath map image: #{image_path}"

    client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

    image_data   = Base64.strict_encode64(File.read(image_path))
    media_type   = image_path.end_with?('.png') ? 'image/png' : 'image/jpeg'

    prompt = <<~PROMPT
      This is a hail swath map showing the geographic path of a hailstorm.

      Please analyze this map and extract the precise geographic boundary of the hail-impacted area.

      Return a JSON object with these fields:
      {
        "description": "plain-language description of the area (e.g., 'eastern Dallas County, bounded by I-635 to the north, US-175 to the south')",
        "counties": ["list", "of", "county", "names"],
        "state": "TX",
        "bbox": {
          "north": <decimal lat>,
          "south": <decimal lat>,
          "east":  <decimal lon>,
          "west":  <decimal lon>
        },
        "key_streets": ["list of major roads or highways that form the boundary"],
        "notes": "any relevant observations about the storm path or density"
      }

      Use the map's legend, street labels, and geographic features to estimate the bounding box.
      If exact coordinates are not determinable from the image, provide your best estimate based
      on visible landmarks.

      Return only the JSON object, no other text.
    PROMPT

    response = client.messages(
      model:      'claude-opus-4-6',
      max_tokens: 1024,
      messages:   [{
        role:    'user',
        content: [
          { type: 'image', source: { type: 'base64', media_type: media_type, data: image_data } },
          { type: 'text',  text:   prompt }
        ]
      }]
    )

    raw = response.content.first.text.strip
    # Strip markdown fences if present
    raw = raw.gsub(/\A```json\s*|\s*```\z/, '').strip
    parsed = JSON.parse(raw, symbolize_names: true)

    # Build a simple polygon from bbox for clipping
    if (bbox = parsed[:bbox])
      parsed[:polygon] = [
        [bbox[:north], bbox[:west]],
        [bbox[:north], bbox[:east]],
        [bbox[:south], bbox[:east]],
        [bbox[:south], bbox[:west]]
      ]
    end

    parsed

  rescue JSON::ParserError => e
    log "Vision analysis returned non-JSON: #{e.message}"
    nil
  rescue StandardError => e
    log "Vision analysis failed: #{e.message}"
    nil
  end

  # ---------------------------------------------------------------------------
  # Step 3: Qualification filter
  # ---------------------------------------------------------------------------
  def self.qualifies?(record)
    state_code = record[:state_code].to_s
    # TX uses specific DPS codes; other states use varying CAMA codes.
    # CadScraperService already pre-filters to commercial before returning records,
    # so for non-TX counties we accept any non-blank code.
    if record[:state_abbr].to_s == 'TX' || record[:state_abbr].blank?
      return false unless COMMERCIAL_STATE_CODES.include?(state_code)
    else
      return false if state_code.blank?
    end
    return false if (record[:sq_ft] || 0) < MIN_SQ_FT
    return false if record[:address].blank?
    true
  end

  # ---------------------------------------------------------------------------
  # Step 4: Clip records to bounding box polygon
  # bbox polygon: [[north_lat, west_lon], [north_lat, east_lon],
  #                [south_lat, east_lon], [south_lat, west_lon]]
  # ---------------------------------------------------------------------------
  def self.clip_to_boundary(records, polygon)
    return records unless polygon&.size == 4

    north = polygon[0][0]
    south = polygon[2][0]
    west  = polygon[0][1]
    east  = polygon[1][1]

    records.select do |r|
      lat = r[:lat]&.to_f
      lon = r[:lon]&.to_f
      next true unless lat && lon  # keep if no coordinates (county-level fallback)

      lat.between?(south, north) && lon.between?(west, east)
    end
  end

  # ---------------------------------------------------------------------------
  # Step 5: Import into pipeline
  # ---------------------------------------------------------------------------
  def self.import_properties(storm, records)
    imported = 0

    records.each do |r|
      next if storm.properties.exists?(address: r[:address], city: r[:city])

      storm.properties.create!(
        address:       r[:address],
        city:          r[:city]          || storm.metro_area,
        state:         r[:state_abbr]    || storm.state,
        county:        r[:county],
        property_type: map_property_type(r[:state_code]),
        sq_ft:         r[:sq_ft]&.to_i,
        owner_entity:  r[:owner_entity],
        roof_system:   nil,  # to be confirmed on inspection
        status:        'identified',
        source:        'cad_auto'
      )
      imported += 1
    rescue ActiveRecord::RecordInvalid => e
      log "Skipping property #{r[:address]}: #{e.message}"
    end

    imported
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def self.map_property_type(state_code)
    case state_code
    when 'F1'           then 'Commercial'
    when 'F2'           then 'Commercial Personal Property'
    when 'L1'           then 'Business Personal Property'
    when 'L2'           then 'Industrial'
    when /\AB[1-4]\z/   then 'Multifamily'
    when /\AX[1-4]\z/   then 'Government'
    when /\AX[5-6]\z/   then 'Church'
    else 'Commercial'
    end
  end

  def self.log(msg)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    Rails.logger.info "[#{timestamp}] MapsOfMeaning: #{msg}"
    puts "[#{timestamp}] MapsOfMeaning: #{msg}"
  end
end

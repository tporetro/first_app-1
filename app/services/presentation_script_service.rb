require 'anthropic'

# Phase 5 — Presentation Script Generation
#
# Generates a personalized, 7-section sales presentation script for each
# property owner, timed for a ~20-minute discovery call. The script is built
# from the enriched contact + property data and the Gamma report URL.
#
# Script sections (from Storm Damage Prospector methodology):
#   1. Introduction & Rapport     (1-2 min)
#   2. The Event                  (1-2 min)
#   3. Their Property             (2-3 min)
#   4. Financial Opportunity      (3-4 min)
#   5. Our Method                 (4-5 min) — Win-in-Advance™
#   6. Urgency & Action Plan      (3-4 min)
#   7. Closing                    (1-2 min)
#
# Each section includes talking points, transition phrases, objection handling,
# and personalization tokens drawn from the lead data.
#
# Usage:
#   script = PresentationScriptService.generate(
#     storm:      storm,
#     properties: [property, ...],
#     contact:    contact,
#     report_url: 'https://gamma.app/docs/...'
#   )
#   # Returns a hash: { owner_entity:, markdown:, sections: [...] }
#
class PresentationScriptService
  CALLER_NAME  = 'Michael Johnson'.freeze
  CALLER_TITLE = 'Director of Commercial Services, Restoration GC'.freeze
  COMPANY      = 'Restoration GC'.freeze
  YEARS_EXP    = 22
  LEGAL_PARTNER = 'Voss Law Firm'.freeze
  LEGAL_TAGLINE = 'Recover Up to 780% More on Your Insurance Claim'.freeze

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------
  def self.generate(storm:, properties:, contact:, report_url:)
    lead = build_lead_context(storm, properties, contact, report_url)
    markdown = compose_script(lead)

    {
      owner_entity: contact.owner_entity,
      markdown:     markdown,
      sections:     parse_sections(markdown)
    }
  rescue StandardError => e
    log "Script generation failed for #{contact.owner_entity}: #{e.message}"
    nil
  end

  # ---------------------------------------------------------------------------
  # Claude composition
  # ---------------------------------------------------------------------------
  def self.compose_script(lead)
    client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

    response = client.messages.create(
      model:      'claude-opus-4-6',
      max_tokens: 4096,
      messages:   [{ role: 'user', content: build_prompt(lead) }]
    )

    response.content.first.text.strip
  end

  def self.build_prompt(lead)
    prop_list = lead[:properties].map { |p|
      "- #{p[:address]}, #{p[:city]} (#{p[:sq_ft] ? ActiveSupport::NumberHelper.number_to_delimited(p[:sq_ft].to_i) : 'unknown'} sq ft, #{p[:property_type]})"
    }.join("\n")

    <<~PROMPT
      You are writing a personalized sales presentation script for #{CALLER_NAME}, #{CALLER_TITLE}.
      The call target is a commercial property owner affected by a recent hailstorm.

      ## Caller Profile
      - Name: #{CALLER_NAME}
      - Title: #{CALLER_TITLE}
      - Company: #{COMPANY}
      - Experience: #{YEARS_EXP} years protecting policyholders
      - Legal partner: #{LEGAL_PARTNER} — "#{LEGAL_TAGLINE}"

      ## Call Target
      - Owner Entity: #{lead[:owner_entity]}
      - Decision Maker: #{lead[:human_owner_name] || 'the owner'}
      - Title: #{lead[:owner_title] || 'unknown'}
      - Phone: #{lead[:owner_phone] || 'unknown'}
      - Email: #{lead[:owner_email] || 'unknown'}
      - Parent Company: #{lead[:parent_company] || 'none'}

      ## Storm Event
      - Storm Date: #{lead[:storm_date]}
      - Hail Size: #{lead[:hail_size]}" (#{hail_descriptor(lead[:hail_size])})
      - County: #{lead[:county]}
      - State: TX

      ## Affected Properties (#{lead[:property_count]} total)
      #{prop_list}

      ## Financial Summary
      - Estimated recoverable value: #{lead[:total_recovery]}
      - Claim deadline: #{lead[:claim_deadline]}

      ## Report
      - Gamma report URL: #{lead[:report_url]}

      ---

      Write a professional, personalized 20-minute discovery call script with EXACTLY these 7 sections.
      Format each section as a Markdown heading (## Section N: Title) followed by structured content.

      For each section include:
      - **Talking Points**: 3-5 bullet points with the actual words to say, personalized to this owner
      - **Transition**: One sentence to move to the next section
      - **Timing**: (X min) note at the heading

      Section 1 — Introduction & Rapport (1-2 min):
        Open with the owner's first name. Establish credibility in one sentence. Respect their time.
        Confirm you're calling about their property/properties specifically (list address(es)).

      Section 2 — The Event (1-2 min):
        Name the specific storm date and hail size. Explain why #{lead[:hail_size]}" hail matters for commercial roofs.
        Make it factual and urgent — not alarmist.

      Section 3 — Their Property (2-3 min):
        Reference their specific building(s) by address. Tie building type and square footage to expected damage patterns.
        Explain that most commercial damage is hidden — membrane puncture, fastener backing, insulation compression.

      Section 4 — Financial Opportunity (3-4 min):
        Present the estimated recoverable value (#{lead[:total_recovery]}) with the specific sq ft math.
        Reference the #{lead[:claim_deadline]} filing deadline. Quantify the cost of inaction.
        Briefly mention Voss Law's "#{LEGAL_TAGLINE}" stat as third-party validation.

      Section 5 — Our Method: Win-in-Advance™ (4-5 min):
        Explain the Win-in-Advance™ approach: forensic documentation before the adjuster arrives.
        Three pillars: (1) drone + core-sample inspection, (2) forensic weather certification,
        (3) expert estimate that becomes the negotiation anchor.
        Contrast with the typical reactive approach where owners accept the carrier's first offer.

      Section 6 — Urgency & Action Plan (3-4 min):
        Remind them the #{lead[:claim_deadline]} deadline is hard. Walk through the exact next steps:
        (1) complimentary inspection (no commitment), (2) we build the file, (3) adjuster meeting,
        (4) if no resolution → Voss Law escalation at zero upfront cost.
        Make the free inspection feel low-friction and logical.

      Section 7 — Closing (1-2 min):
        Ask for the inspection appointment directly. Offer two specific time slots.
        Confirm their email to send the report link (#{lead[:report_url]}).
        If they hesitate, use the objection guide below.

      ## Objection Handling (append as a final section titled "## Objection Handling")
      Write short 2-3 sentence responses for each objection:
      - "My carrier already handled it / I already filed."
      - "I don't have time for this right now."
      - "I don't think my roof was damaged."
      - "I need to talk to my property manager / partner first."
      - "How much does this cost?"

      Return only the Markdown script — no preamble, no meta-commentary.
    PROMPT
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def self.build_lead_context(storm, properties, contact, report_url)
    total_recovery = properties.sum { |p| ((p.sq_ft || 0) * ReportTemplateService::COST_PER_SQFT).to_i }
    deadline = (storm.event_date >> ReportTemplateService::CLAIM_WINDOW_MONTHS).strftime('%B %-d, %Y')

    {
      owner_entity:     contact.owner_entity,
      human_owner_name: contact.human_owner_name,
      owner_title:      contact.owner_title,
      owner_phone:      contact.owner_phone,
      owner_email:      contact.owner_email,
      parent_company:   contact.parent_company,
      storm_date:       storm.event_date.strftime('%B %-d, %Y'),
      hail_size:        storm.hail_size,
      county:           properties.map(&:county).uniq.join(', '),
      property_count:   properties.size,
      total_recovery:   ReportTemplateService.fmt_dollars(total_recovery),
      claim_deadline:   deadline,
      report_url:       report_url,
      properties:       properties.map { |p|
        { address: p.address, city: p.city, sq_ft: p.sq_ft, property_type: p.property_type }
      }
    }
  end

  def self.hail_descriptor(size)
    case size.to_f
    when 0...1.0  then 'pea-sized'
    when 1.0...1.5 then 'quarter-sized'
    when 1.5...1.75 then 'golf ball (threshold for significant commercial damage)'
    when 1.75...2.0 then 'golf ball'
    when 2.0...2.5 then 'tennis ball'
    else               'baseball or larger — severe'
    end
  end

  # Extract section titles from the rendered markdown for structured access
  def self.parse_sections(markdown)
    markdown.scan(/^##\s+(.+)$/).flatten
  end

  def self.log(msg)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    Rails.logger.info "[#{timestamp}] PresentationScript: #{msg}"
    puts "[#{timestamp}] PresentationScript: #{msg}"
  end
end

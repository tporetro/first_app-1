# Generates Gamma-ready markdown for two report types:
#
#   ReportTemplateService.render_property(storm:, property:)
#     → Individual property technical report (single-property owners OR
#       drill-down from portfolio overview)
#
#   ReportTemplateService.render_portfolio(storm:, properties:, property_report_urls:)
#     → Portfolio Intelligence Brief (multi-property owners)
#       property_report_urls: { property.id => gamma_url, ... }
#
# Both are branded Restoration GC. Neither says "contact a contractor" — they
# sell the Win-in-Advance™ process and direct to Michael/Amy.
class ReportTemplateService
  COST_PER_SQFT = 15  # $/sq ft replacement cost (matches Manus baseline)

  # ── Team credentials — update as team grows ──────────────────────────────
  TEAM = {
    name:             'Michael Johnson',
    title:            'Director of Commercial Services',
    phone:            '(512) 621-4201',
    email:            'michael@rgcroof.com',
    amy:              'amy@rgcroof.com',
    company:          'Restoration GC',
    years_experience: 22
  }.freeze

  # ── Legal partner — Commercial Policyholder Attorneys ────────────────────
  LEGAL_PARTNER = {
    name:          'The Voss Law Firm, P.C.',
    tagline:       'Commercial Policyholder Attorneys',
    phone:         '866-276-6179',
    web:           'www.DeniedClaim.com',
    fee:           'No fee if no recovery on all cases',
    avg_return:    '780%',   # published: "Recover Up to 780% More on Your Insurance Claim"
    availability:  '24 hours a day, 7 days a week, 365 days a year',
    claim_types:   %w[Industrial Marine Condominium Commercial Agricultural Governmental Church Residential],
    # Media credentials — as seen in
    media: ['CBS', 'NBC', 'ABC', 'Forbes', 'Lifetime', 'Inc. 500', 'Houston Press', 'News 92 FM'],
    # Legal industry recognition
    awards: [
      'Super Lawyers',
      'Super Lawyers Rising Stars',
      'Million Dollar Advocates Forum',
      'The National Trial Lawyers — Top 100 Trial Lawyers',
      'The National Top 40 Under 40 Trial Lawyers',
      "Houston's Top Lawyers — H Texas"
    ],
    # 5-stage case cycle (from published diagram)
    case_cycle: [
      { stage: 'Client Meeting',       detail: 'Engage legal services — free consultation' },
      { stage: 'Investigate',          detail: 'Full forensic analysis of loss' },
      { stage: 'Define Course',        detail: 'Formal demand letter to carrier' },
      { stage: 'Negotiate',            detail: 'Secure maximum offer' },
      { stage: 'Resolution & Payment', detail: 'Settlement proceeds to client' }
    ],
    services: [
      'Review your policy coverage',
      'Assess the extent of the loss',
      'Assign a Claim Support Analyst to your claim',
      'Document and present your claim',
      'Bring adjusters, accountants, engineers, contractors, and photographers',
      'Use state-of-the-art software to analyze the loss',
      'Negotiate your settlement',
      'Ensure deadlines are not missed',
      'Coordinate with your mortgage company for timely fund release'
    ]
  }.freeze

  # ── Michael Johnson — expert credentials ─────────────────────────────────
  # Set status: 'published' once the issue is confirmed live; use 'forthcoming' until then.
  MICHAEL_PRESS = [
    { outlet: 'Roofing Contractor Magazine', role: 'Featured expert on storm damage', status: 'forthcoming' }
  ].freeze

  # ── Voss Law "First Offer vs. Settlement" results (from published document)
  VOSS_RESULTS = [
    { type: 'Industrial Commercial Property', offer: '$75,000',  recovery: '$5,400,000' },
    { type: 'National Chain Hotel',           offer: '$50,000',  recovery: '$3,000,000' },
    { type: 'Apartment Complex',              offer: '$25,000',  recovery: '$800,000'   },
    { type: 'Dental Facilities',              offer: '$25,000',  recovery: '$800,000'   },
    { type: 'Air Conditioning Company',       offer: '$0',       recovery: '$1,500,000' },
    { type: 'Local Houston Hotel',            offer: '$50,000',  recovery: '$1,400,000' },
    { type: 'Apartment Complex',              offer: '$0',       recovery: '$750,000'   },
    { type: 'Apartment Complex',              offer: '$0',       recovery: '$425,000'   },
    { type: 'Shopping Center',                offer: '$0',       recovery: '$400,000'   }
  ].freeze

  # ── Claims filing window (months from storm date) ─────────────────────────
  CLAIM_WINDOW_MONTHS = 12

  # ── Verified case studies — signed reference letters on file ─────────────
  PROVEN_RESULTS = [
    { label: 'Galveston Condo',         carrier_offer: '$0 (Denied outright)', recovery: '$16,000,000' },
    { label: 'Houston Hotel',           carrier_offer: '$100,000',             recovery: '$5,500,000'  },
    { label: 'Dallas Warehouse',        carrier_offer: '$92,000',              recovery: '$3,450,000'  },
    { label: 'Garden Ridge Pottery (Original Schertz Location)',
                                        carrier_offer: 'Disputed',             recovery: '$4,200,000'  },
    { label: 'State of Texas — Region 13 ESC (Austin)',
                                        carrier_offer: 'Denied outright',      recovery: '$800,000+'   }
  ].freeze

  # ---------------------------------------------------------------------------
  # Individual Property Technical Report
  # ---------------------------------------------------------------------------
  def self.render_property(storm:, property:)
    sq_ft         = property.sq_ft || 50_000
    replacement   = (sq_ft * COST_PER_SQFT).to_i
    hail_size     = storm.hail_size
    storm_date    = storm.event_date.strftime('%B %-d, %Y')
    storm_date_db = storm.event_date
    deadline      = (storm_date_db >> CLAIM_WINDOW_MONTHS).strftime('%B %-d, %Y')
    days_elapsed  = (Date.today - storm_date_db).to_i
    days_remaining = (storm_date_db >> CLAIM_WINDOW_MONTHS - Date.today).to_i rescue 0
    county        = property.county
    address       = property.address

    damage_prob, urgency = damage_profile(hail_size)
    roof_type     = property.roof_system || inferred_roof_type(property)

    <<~MARKDOWN
      # Confidential: Property Damage Intelligence Report

      **#{address}, #{property.city}, #{property.state}**
      Prepared by #{TEAM[:company]} | #{Date.today.strftime('%B %-d, %Y')}

      ---

      ## Executive Summary

      On #{storm_date}, a severe hailstorm produced **#{hail_size}-inch hailstones** across #{county} County,
      placing #{address} directly in the documented damage path.

      Our forensic analysis indicates a **#{damage_prob} probability** of significant, potentially undetected
      roof damage at this property. At #{sq_ft.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} sq ft,
      the estimated insurance recovery value is **#{fmt_dollars(replacement)}**.

      > **Filing Deadline: #{deadline}** — #{days_remaining > 0 ? "#{days_remaining} days remaining" : 'DEADLINE PASSED — act immediately'}.
      > #{days_elapsed} days have elapsed since the storm.

      ---

      ## Storm Event Analysis

      | | |
      |---|---|
      | Storm Date | #{storm_date} |
      | Hail Size | **#{hail_size} inches** |
      | Wind Gusts | Up to 65 mph (typical for events of this magnitude) |
      | County | #{county} |
      | Storm Severity | #{hail_size >= 2.0 ? 'SEVERE — exceeds all commercial roofing thresholds' : 'LARGE — exceeds flat commercial roof penetration threshold'} |

      Hail of #{hail_size} inches is #{hail_comparison(hail_size)}. At this size, all commercial
      roofing systems — TPO, EPDM, modified bitumen, BUR — sustain documented damage that may
      not be visible without professional forensic inspection.

      ---

      ## Property Profile

      | | |
      |---|---|
      | Address | #{address} |
      | Building Type | #{property.property_type || 'Commercial / Industrial'} |
      | Roof Size | #{sq_ft.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} sq ft |
      | Roof System | #{roof_type} |
      | Owner | #{property.owner_entity} |

      ---

      ## Damage Assessment

      **Probability of Actionable, Claimable Damage: #{damage_prob}**

      At #{hail_size} inches, documented failure modes include:

      - **Membrane punctures and tears** (TPO/EPDM) — immediate water intrusion risk
      - **Granule loss and surfacing fracture** (modified bitumen / BUR) — accelerated UV degradation
      - **Seam separation** — hail impact compromises heat-welded or adhered seams
      - **HVAC equipment damage** — condensers, curbs, and rooftop units sustain cosmetic and mechanical damage
      - **Perimeter flashing failure** — leads to concealed wall cavity moisture intrusion
      - **Skylight and smoke vent damage** — often missed in standard inspections

      Hidden moisture intrusion from undetected hail damage compounds at a documented
      rate of **2.3× over 12 months** — meaning a #{fmt_dollars(replacement)} claim today
      may become a #{fmt_dollars((replacement * 2.3).to_i)} remediation problem by #{(storm_date_db >> 12).strftime('%B %Y')}.

      ---

      ## Financial Analysis

      | | |
      |---|---|
      | Roof Area | #{sq_ft.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} sq ft |
      | Replacement Cost ($/sq ft) | $#{COST_PER_SQFT} |
      | **Estimated Insurance Recovery** | **#{fmt_dollars(replacement)}** |
      | Deferred Cost Multiplier (12 mo) | 2.3× → #{fmt_dollars((replacement * 2.3).to_i)} |
      | Filing Deadline | **#{deadline}** |

      This estimate reflects industry-standard large-loss commercial roofing replacement rates
      and does not include HVAC, equipment, or interior damage — which frequently add 15–25%
      to final claim value.

      ---

      ## Why Most Large-Loss Claims Are Underpaid

      Insurance carriers have a financial incentive to minimize payouts. Without a professionally
      prepared claim, property owners routinely receive 40–60 cents on the dollar.

      The three most common failure points:

      1. **Incomplete documentation** — damage is present but not formally established through
         engineering-level analysis before the claim is filed
      2. **Incorrect scope** — the carrier's adjuster defines the scope; an independent engineer
         defines it correctly
      3. **No legal leverage** — when a carrier disputes a claim, most property owners have no
         recourse other than accepting the lowball offer

      ---

      ## The Win-in-Advance™ Approach

      **#{TEAM[:name]}** has spent **#{TEAM[:years_experience]} years** protecting commercial
      policyholders and is a recognized expert on storm damage#{MICHAEL_PRESS.first[:status] == 'published' ? ', as featured in *Roofing Contractor Magazine*' : ''}.
      He works alongside **#{LEGAL_PARTNER[:name]}** — #{LEGAL_PARTNER[:tagline]}, as seen in
      #{LEGAL_PARTNER[:media].first(4).join(', ')}, and others.

      Voss Law's published benchmark: clients recover **up to #{LEGAL_PARTNER[:avg_return]}
      more** than the carrier's initial offer once legal representation is in place.

      #{TEAM[:company]}'s process is built around one principle: **present a claim so completely
      that the carrier's only rational response is full payment.**

      | Stage | What We Do |
      |---|---|
      | **Forensic Inspection** | Licensed engineers document all damage and correlate findings to storm weather data |
      | **Engineering Report** | Stamped causation report eliminates the carrier's primary denial argument |
      | **Public Adjuster Management** | Licensed PAs prepare and present the claim in the carrier's own language |
      | **Legal Representation** | #{LEGAL_PARTNER[:name]} — #{LEGAL_PARTNER[:fee]} — applies the legal pressure that changes outcomes |
      | **Restoration** | Licensed GC team executes the project from permit to warranty |

      **If the carrier disputes, the Voss Law case cycle takes over:**

      | Step | Action |
      |---|---|
      #{LEGAL_PARTNER[:case_cycle].map { |s| "| **#{s[:stage]}** | #{s[:detail]} |" }.join("\n      ")}

      When carriers push back, Voss Law's published track record includes:

      | Property Type | Carrier's Offer | Settlement |
      |---|---|---|
      #{VOSS_RESULTS.first(4).map { |r| "| #{r[:type]} | #{r[:offer]} | **#{r[:recovery]}** |" }.join("\n      ")}

      **You pay nothing out of pocket until your claim is approved and funded.**

      ---

      ## Proven Results

      These are verified recoveries with signed reference letters on file.

      | Property | Carrier's Offer | Our Recovery |
      |---|---|---|
      #{PROVEN_RESULTS.map { |r| "| #{r[:label]} | #{r[:carrier_offer]} | **#{r[:recovery]}** |" }.join("\n      ")}

      > *"After showing us the map of the storm, Mr. Johnson and his team were given permission
      > to inspect. To our surprise, the roofs, wall panels, and AC units were all heavily damaged
      > by hail. Mr. Johnson was able to get us over four million dollars to repair the damage."*
      >
      > — **Eric W. White, Founder & CEO, Garden Ridge Pottery**

      > *"Thanks to Michael we received $1.2 million from hail damage we were unaware of.
      > He was able to tell us ahead of time what was going to happen and why — and he was right
      > every time."*
      >
      > — **Luke Martin, Executive Director, Texas Education Service Center Region 13 (State of Texas)**

      ---

      ## Recommended Next Step

      Request a complimentary forensic inspection. Our team comes to the property,
      documents current conditions at no cost, and gives you a clear picture of
      what you have and what it's worth before you decide anything.

      This is not a sales call. It's a 90-minute inspection that gives you the facts.

      **#{TEAM[:name]}**, #{TEAM[:title]}
      #{TEAM[:phone]} | #{TEAM[:email]}

      *Amy on our team will reach out to schedule at your convenience: #{TEAM[:amy]}*

      ---

      *This report was prepared by #{TEAM[:company]} using forensic weather data correlated to the
      subject property location. Damage probability is an analytical estimate; actual damage
      can only be confirmed through on-site forensic inspection. #{TEAM[:company]} is a licensed
      general contractor specializing in large-loss commercial storm damage restoration.*
    MARKDOWN
  end

  # ---------------------------------------------------------------------------
  # Portfolio Intelligence Brief (multi-property owners)
  # property_report_urls: { property.id => gamma_url, ... }
  # ---------------------------------------------------------------------------
  def self.render_portfolio(storm:, properties:, owner_entity:, contact: nil, property_report_urls: {})
    total_sq_ft    = properties.sum { |p| p.sq_ft || 0 }
    total_recovery = properties.sum { |p| ((p.sq_ft || 0) * COST_PER_SQFT).to_i }
    count          = properties.size
    storm_date     = storm.event_date.strftime('%B %-d, %Y')
    storm_date_db  = storm.event_date
    deadline       = (storm_date_db >> CLAIM_WINDOW_MONTHS).strftime('%B %-d, %Y')
    days_elapsed   = (Date.today - storm_date_db).to_i
    first_name     = contact&.human_owner_name&.split&.first || 'Team'

    # Build property table rows
    property_rows = properties.map do |p|
      recovery = ((p.sq_ft || 0) * COST_PER_SQFT).to_i
      report_url = property_report_urls[p.id]
      link = report_url ? "[View Full Report](#{report_url})" : 'Report pending'
      "| #{p.address} | #{p.city} | #{storm.event_date.strftime('%b %-d, %Y')} | #{storm.hail_size}\" | #{fmt_dollars(recovery)} | #{link} |"
    end.join("\n")

    <<~MARKDOWN
      # CONFIDENTIAL: Portfolio Damage Intelligence Brief

      **To:** #{owner_entity}#{contact ? " — #{contact.human_owner_name}, #{contact.owner_title}" : ''}
      **From:** #{TEAM[:company]}
      **Date:** #{Date.today.strftime('%B %-d, %Y')}
      **Re:** #{count} #{count == 1 ? 'Property' : 'Properties'} — Documented Hail Exposure — #{fmt_dollars(total_recovery)} Estimated Recovery

      ---

      ## Executive Summary

      #{first_name}, our forensic weather analysis of the #{storm_date} storm system confirms
      that **#{count} of your properties** were in the direct path of hail up to **#{storm.hail_size} inches**.

      Based on our initial assessment, the estimated insurance recovery value across this
      portfolio is **#{fmt_dollars(total_recovery)}**. The filing window closes **#{deadline}** —
      #{days_elapsed} days have already elapsed.

      ---

      ## Affected Portfolio Properties

      | Property | City | Storm Date | Hail Size | Est. Recovery | Detail |
      |---|---|---|---|---|---|
      #{property_rows}
      | **PORTFOLIO TOTAL** | | | | **#{fmt_dollars(total_recovery)}** | |

      ---

      ## Why This Matters Now

      Most property owners don't know they have storm damage. Hail damage to commercial flat
      roofs is frequently invisible from ground level — even a 4-inch hailstone leaves no
      visible breach on a TPO membrane, but causes seam stress fractures that allow water
      intrusion within 6–18 months.

      By the time the damage is obvious — ceiling stains, HVAC failures, tenant complaints —
      the insurance filing window has often closed. The recovery opportunity is gone.

      **#{days_elapsed} days of that window have already been used.**

      ---

      ## Why Most Large-Loss Claims Are Underpaid

      Carriers settle large-loss commercial claims for 40–60 cents on the dollar when the
      claim arrives without complete forensic documentation. The carrier's adjuster sets
      the scope. Without an independent engineer and a licensed PA challenging that scope,
      the lowball offer becomes the final number.

      The three reasons claims fail:

      1. **No causation proof** — without a stamped engineering report, the carrier can
         attribute damage to "wear and tear" rather than the storm
      2. **Incomplete scope** — the adjuster misses 20–30% of legitimate damage items
      3. **No leverage** — property owners who don't have legal representation accept
         what they're offered

      ---

      ## The Win-in-Advance™ Approach

      #{TEAM[:company]}'s methodology transforms the claims process from a reactive negotiation
      into a strategically prepared presentation that compels carrier action.

      Our integrated team answers the three questions that determine claim outcomes *before*
      the claim is ever filed:

      | Question | Our Answer |
      |---|---|
      | What caused the damage? | Forensic weather data + site correlation |
      | What failed, and why? | Stamped engineering analysis + lab testing if needed |
      | What is the true scope and cost? | Independent large-loss estimator, not the carrier's adjuster |

      When a claim arrives fully formed and professionally supported, the carrier's
      rational response is prompt, full payment.

      ---

      ## About the Team

      **#{TEAM[:name]}** has spent **#{TEAM[:years_experience]} years** protecting commercial
      policyholders and is a recognized expert on storm damage#{MICHAEL_PRESS.first[:status] == 'published' ? ', as featured in *Roofing Contractor Magazine*' : ''}.

      He works alongside **#{LEGAL_PARTNER[:name]}** — #{LEGAL_PARTNER[:tagline]}.

      > *As seen in: #{LEGAL_PARTNER[:media].join(' · ')}*
      > *Recognized by: #{LEGAL_PARTNER[:awards].first(3).join(' · ')}*

      Voss Law publishes this benchmark: clients recover **up to #{LEGAL_PARTNER[:avg_return]}
      more** than the carrier's initial offer once legal representation is in place.

      #{TEAM[:company]} brings a complete recovery team to every large-loss claim:

      - **Licensed Engineers** — forensic analysis, stamped causation reports
      - **Certified Public Adjusters** — licensed claim preparation and carrier negotiation
      - **#{LEGAL_PARTNER[:name]}** — #{LEGAL_PARTNER[:fee]}
      - **General Contractor** — licensed restoration execution from permit to warranty

      **If the carrier disputes, the Voss Law 5-stage case cycle takes over:**

      | Step | Action |
      |---|---|
      #{LEGAL_PARTNER[:case_cycle].map { |s| "| **#{s[:stage]}** | #{s[:detail]} |" }.join("\n      ")}

      Voss Law's published "First Offer vs. Settlement Actuals":

      | Property Type | Carrier's Offer | Settlement |
      |---|---|---|
      #{VOSS_RESULTS.first(5).map { |r| "| #{r[:type]} | #{r[:offer]} | **#{r[:recovery]}** |" }.join("\n      ")}

      *Full results: #{LEGAL_PARTNER[:web]} | #{LEGAL_PARTNER[:phone]}*

      **You pay nothing out of pocket until your claim is approved and funded.**

      ---

      ## Proven Results

      These are verified recoveries with signed reference letters on file.

      | Property | Carrier's Offer | Our Recovery |
      |---|---|---|
      #{PROVEN_RESULTS.map { |r| "| #{r[:label]} | #{r[:carrier_offer]} | **#{r[:recovery]}** |" }.join("\n      ")}

      > *"After showing us the map of the storm, Mr. Johnson and his team were given permission
      > to inspect. To our surprise, the roofs, wall panels, and AC units were all heavily damaged
      > by hail. Mr. Johnson was able to get us over four million dollars to repair the damage."*
      >
      > — **Eric W. White, Founder & CEO, Garden Ridge Pottery**

      > *"Thanks to Michael we received $1.2 million from hail damage we were unaware of.
      > He was able to tell us ahead of time what was going to happen and why — and he was right
      > every time."*
      >
      > — **Luke Martin, Executive Director, Texas Education Service Center Region 13 (State of Texas)**

      ---

      ## Recommended Next Step

      We recommend a complimentary, no-obligation portfolio review — a single conversation
      with our team to walk through each property, the storm data, and what a realistic
      recovery looks like before you decide anything.

      This is not a commitment. It's the information you need to make a decision.

      **#{TEAM[:name]}**, #{TEAM[:title]}
      #{TEAM[:phone]} | #{TEAM[:email]}

      *Amy on our team will reach out to schedule a time that works for you: #{TEAM[:amy]}*

      ---

      *This brief was prepared by #{TEAM[:company]} using forensic weather data correlated to each
      subject property location. Recovery estimates reflect industry-standard large-loss commercial
      roofing replacement rates ($#{COST_PER_SQFT}/sq ft) and are subject to on-site verification.
      #{TEAM[:company]} is a licensed general contractor specializing in large-loss commercial storm
      damage restoration, working alongside licensed public adjusters and insurance attorneys.*
    MARKDOWN
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def self.fmt_dollars(amount)
    "$#{amount.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}"
  end

  def self.damage_profile(hail_size)
    case hail_size
    when 0..1.49  then ['Moderate (55–65%)',  'ELEVATED']
    when 1.5..1.99 then ['High (72–82%)',     'HIGH']
    when 2.0..2.99 then ['Very High (85–92%)', 'CRITICAL']
    else               ['Extreme (95%+)',      'CRITICAL']
    end
  end

  def self.hail_comparison(size)
    case size
    when 0..0.99  then 'the size of a marble'
    when 1.0..1.49 then 'the size of a quarter'
    when 1.5..1.99 then 'the size of a golf ball — the threshold for confirmed commercial roof damage'
    when 2.0..2.49 then 'the size of a hen egg — severe by any insurance standard'
    when 2.5..2.99 then 'the size of a tennis ball — among the largest commercially documented hail sizes'
    else 'the size of a baseball or larger — among the most destructive hail events on record'
    end
  end

  def self.inferred_roof_type(property)
    # Infer from construction era if not specified
    return 'TPO single-ply membrane (most common post-2000 commercial)' unless property.respond_to?(:year_built)
    'TPO/EPDM single-ply or modified bitumen (to be confirmed on inspection)'
  end
end

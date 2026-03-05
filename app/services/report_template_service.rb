# Renders the Gamma-ready markdown report for a single property.
# Mirrors references/technical_report_template.md with string substitution.
class ReportTemplateService
  REPLACEMENT_COST_LOW  = 8   # $/sq ft
  REPLACEMENT_COST_HIGH = 12  # $/sq ft

  def self.render(storm:, property:)
    sq_ft       = property.sq_ft || 50_000
    low_cost    = (sq_ft * REPLACEMENT_COST_LOW).to_i
    high_cost   = (sq_ft * REPLACEMENT_COST_HIGH).to_i
    hail_size   = storm.hail_size
    storm_date  = storm.event_date.strftime('%B %-d, %Y')
    county      = property.county
    address     = property.address

    # Damage probability based on hail size
    damage_prob = case hail_size
                  when 0..1.49 then 'Low (35%)'
                  when 1.5..1.99 then 'Moderate-High (65%)'
                  when 2.0..2.49 then 'High (82%)'
                  else 'Critical (95%+)'
                  end

    <<~MARKDOWN
      # URGENT: Forensic Hail Damage Intelligence Report

      **CONFIDENTIAL** | Prepared by Restoration GC | #{Date.today.strftime('%B %-d, %Y')}

      ---

      ## Executive Summary

      This report documents **undisclosed storm damage risk** at **#{address}** following the #{storm_date} hail event
      that produced #{hail_size}-inch hailstones across #{county} County.
      Immediate forensic inspection is recommended before carrier documentation deadlines close.

      ---

      ## Storm Event Profile

      | Field | Detail |
      |---|---|
      | Event Date | #{storm_date} |
      | Hail Size | **#{hail_size} inches** |
      | Affected County | #{county} |
      | Metro Area | #{storm.metro_area} |
      | Storm Category | #{hail_size >= 2.0 ? 'Severe — Significant structural impact expected' : 'Large — Commercial roof penetration likely'} |

      ---

      ## Property Profile

      | Field | Detail |
      |---|---|
      | Address | #{address} |
      | City/State | #{property.city}, #{property.state} |
      | Property Type | #{property.property_type || 'Commercial'} |
      | Estimated Sq Ft | #{sq_ft.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} |
      | Roof System | #{property.roof_system || 'TPO/Modified Bitumen (to be confirmed on inspection)'} |
      | Owner Entity | #{property.owner_entity} |

      ---

      ## Damage Probability Assessment

      **Probability of Actionable Damage: #{damage_prob}**

      Hailstones >= 1.5 inches are scientifically documented to cause:

      - Granule loss and membrane bruising on flat commercial roofs
      - HVAC equipment denting and condenser fin damage
      - Skylight cracking and perimeter flashing failure
      - Hidden moisture intrusion that escalates over 90–180 days

      At #{hail_size} inches, the #{storm_date} event exceeds the threshold for **mandatory forensic inspection**
      under most commercial property insurance policies.

      ---

      ## Financial Impact Analysis

      | Scenario | Estimate |
      |---|---|
      | Replacement Cost (Low) | **$#{low_cost.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}** |
      | Replacement Cost (High) | **$#{high_cost.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse}** |
      | Cost Range ($/sq ft) | $#{REPLACEMENT_COST_LOW}–$#{REPLACEMENT_COST_HIGH} |
      | Deferred Damage Multiplier | 2.3× (industry average if unaddressed past 12 months) |

      ---

      ## Dual Opportunity Framework

      This event represents both a **liability concern** and a **strategic capital improvement opportunity**:

      1. **Insurance Recovery**: Document and file before policy deadlines (typically 12–24 months from event)
      2. **Capital Improvement**: Modernize roofing system, qualify for energy incentives
      3. **Asset Protection**: Prevent moisture intrusion from compounding structural costs

      ---

      ## Recommended Action Plan

      - [ ] Schedule forensic roof inspection within 30 days
      - [ ] Engage public adjuster or contractor to document damage pre-claim
      - [ ] File insurance claim with carrier using documented evidence
      - [ ] Obtain competitive bids from licensed commercial roofing contractors
      - [ ] Review lease terms for tenant responsibility clauses

      ---

      ## About Restoration GC

      Restoration GC specializes in enterprise-grade forensic weather analysis and commercial roof restoration.
      Our team has documented and recovered **$XXM+** in storm claims for commercial property portfolios.

      **Contact**: Michael Johnson, Director of Commercial Services
      **Phone**: (512) 621-4201 | **Email**: michael@restorationgc.net

      *To schedule your complimentary forensic inspection, reply to this email or contact Amy at amy@restorationgc.net.*
    MARKDOWN
  end
end

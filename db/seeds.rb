# Dallas Demo Seed Data
# Run with: rake db:seed  OR  rake demo:seed_dallas
#
# Populates the dashboard with a realistic Dallas-area hailstorm scenario:
#   - 1 storm event (DFW Hailstorm, March 3 2026)
#   - 10 commercial properties across Dallas County
#   - 10 enriched owner contacts
#   - Email outreaches with varied engagement (sent, opened, clicked, replied)

puts "Seeding Dallas demo data..."

# ─────────────────────────────────────────────
# 1. STORM EVENT
# ─────────────────────────────────────────────
storm = StormEvent.find_or_initialize_by(
  event_date: Date.new(2026, 3, 3),
  state:      "TX",
  metro_area: "Dallas-Fort Worth"
)
storm.assign_attributes(
  name:                "DFW Hailstorm – March 3, 2026",
  hail_size:           2.00,
  counties:            "Dallas, Tarrant",
  boundary_definition: "Hail swath covering central and northwest Dallas, roughly bounded by I-35E, I-635, TX-183, and Loop 12. Peak hail diameter 2.0\" (golf ball size) near Love Field and Medical District corridors.",
  status:              "complete",
  notes:               "NOAA SPC storm report confirmed. 47 commercial properties identified in swath. Contact enrichment complete. Initial outreach sent."
)
storm.save!
puts "  Storm: #{storm.name} (id=#{storm.id})"

# ─────────────────────────────────────────────
# 2. PROPERTIES
# ─────────────────────────────────────────────
properties_data = [
  {
    address: "4200 Maple Ave", city: "Dallas", county: "Dallas",
    property_type: "Office/Retail", sq_ft: 28_400, roof_system: "TPO Membrane",
    owner_entity: "Maple Properties Group LLC", source: "cad_auto", status: "emailed"
  },
  {
    address: "8901 Stemmons Fwy", city: "Dallas", county: "Dallas",
    property_type: "Warehouse/Industrial", sq_ft: 64_200, roof_system: "Metal Standing Seam",
    owner_entity: "Stemmons Industrial Holdings Inc", source: "cad_auto", status: "emailed"
  },
  {
    address: "3300 Oak Lawn Ave", city: "Dallas", county: "Dallas",
    property_type: "Mixed Use", sq_ft: 41_800, roof_system: "Built-Up Roofing (BUR)",
    owner_entity: "Oak Lawn Ventures LP", source: "cad_auto", status: "emailed"
  },
  {
    address: "1500 Market Center Blvd", city: "Dallas", county: "Dallas",
    property_type: "Retail", sq_ft: 33_100, roof_system: "TPO Membrane",
    owner_entity: "Market Center Realty Inc", source: "cad_auto", status: "emailed"
  },
  {
    address: "6100 LBJ Freeway", city: "Dallas", county: "Dallas",
    property_type: "Office", sq_ft: 87_500, roof_system: "EPDM Membrane",
    owner_entity: "LBJ Office Partners LLC", source: "cad_auto", status: "emailed"
  },
  {
    address: "2800 Commerce St", city: "Dallas", county: "Dallas",
    property_type: "Warehouse", sq_ft: 51_600, roof_system: "Metal Standing Seam",
    owner_entity: "Commerce Street Holdings LLC", source: "cad_auto", status: "emailed"
  },
  {
    address: "9201 Forest Ln", city: "Dallas", county: "Dallas",
    property_type: "Retail Strip Center", sq_ft: 22_300, roof_system: "TPO Membrane",
    owner_entity: "Forest Lane Properties LLC", source: "cad_auto", status: "emailed"
  },
  {
    address: "4500 Harry Hines Blvd", city: "Dallas", county: "Dallas",
    property_type: "Medical Office", sq_ft: 38_700, roof_system: "Modified Bitumen",
    owner_entity: "Harry Hines Medical Properties LP", source: "cad_auto", status: "reported"
  },
  {
    address: "1100 Inwood Rd", city: "Dallas", county: "Dallas",
    property_type: "Industrial/Flex", sq_ft: 47_900, roof_system: "Metal Panel",
    owner_entity: "Inwood Industrial Group LLC", source: "cad_auto", status: "enriched"
  },
  {
    address: "7200 Greenville Ave", city: "Dallas", county: "Dallas",
    property_type: "Mixed Use/Retail", sq_ft: 19_800, roof_system: "Built-Up Roofing (BUR)",
    owner_entity: "Greenville Ave Capital Partners", source: "cad_auto", status: "emailed"
  }
]

properties = properties_data.map do |attrs|
  p = Property.find_or_initialize_by(
    storm_event: storm,
    address:     attrs[:address],
    city:        attrs[:city]
  )
  p.assign_attributes(attrs.merge(state: "TX"))
  p.save!
  puts "  Property: #{p.address} – #{p.owner_entity}"
  p
end

# ─────────────────────────────────────────────
# 3. CONTACTS (enriched owner decision-makers)
# ─────────────────────────────────────────────
contacts_data = [
  {
    owner_entity: "Maple Properties Group LLC",
    human_owner_name: "Derek Fontaine", owner_title: "Managing Partner",
    owner_email: "d.fontaine@maplepropertiesgroup.com", owner_phone: "214-555-0182",
    owner_linkedin: "linkedin.com/in/derekfontaine-dallas",
    org_domain: "maplepropertiesgroup.com", enrichment_source: "apollo",
    email_verified: true, status: "enriched", deal_status: "in_negotiation",
    notes: "Very responsive. Mentioned they had hail damage in 2023 as well. Interested in full roof assessment.",
    last_activity_at: 2.days.ago
  },
  {
    owner_entity: "Stemmons Industrial Holdings Inc",
    human_owner_name: "Patricia Ng", owner_title: "VP of Asset Management",
    owner_email: "png@stemmonsih.com", owner_phone: "214-555-0347",
    owner_linkedin: "linkedin.com/in/patricia-ng-stemmons",
    org_domain: "stemmonsih.com", enrichment_source: "apollo",
    email_verified: true, status: "enriched", deal_status: "prospecting",
    notes: "Opened email twice. Has not replied yet.",
    last_activity_at: 4.days.ago
  },
  {
    owner_entity: "Oak Lawn Ventures LP",
    human_owner_name: "Marcus Delgado", owner_title: "Principal",
    owner_email: "mdelgado@oaklawnventures.com", owner_phone: "214-555-0519",
    owner_linkedin: "linkedin.com/in/marcusdelgado",
    org_domain: "oaklawnventures.com", enrichment_source: "secretary_of_state",
    email_verified: true, status: "enriched", deal_status: "won",
    notes: "Scheduled site visit for March 10. HOT LEAD – confirmed hail damage on all 3 roofs.",
    last_activity_at: 1.day.ago
  },
  {
    owner_entity: "Market Center Realty Inc",
    human_owner_name: "Sandra Okafor", owner_title: "Director of Property Operations",
    owner_email: "sokafor@marketcenterrealty.com", owner_phone: "972-555-0234",
    owner_linkedin: "linkedin.com/in/sandra-okafor-realty",
    org_domain: "marketcenterrealty.com", enrichment_source: "apollo",
    email_verified: true, status: "enriched", deal_status: "prospecting",
    notes: nil,
    last_activity_at: 5.days.ago
  },
  {
    owner_entity: "LBJ Office Partners LLC",
    human_owner_name: "Robert Yuen", owner_title: "CFO",
    owner_email: "ryuen@lbjofficepartners.com", owner_phone: "972-555-0788",
    owner_linkedin: "linkedin.com/in/robertyuen-cre",
    org_domain: "lbjofficepartners.com", enrichment_source: "website",
    email_verified: true, status: "enriched", deal_status: "prospecting",
    notes: "Clicked Gamma report link. Good signal.",
    last_activity_at: 3.days.ago
  },
  {
    owner_entity: "Commerce Street Holdings LLC",
    human_owner_name: "Tanya Williamson", owner_title: "Owner",
    owner_email: "twilliamson@csholdings.com", owner_phone: "214-555-0961",
    owner_linkedin: nil,
    org_domain: "csholdings.com", enrichment_source: "secretary_of_state",
    email_verified: false, status: "enriched", deal_status: "prospecting",
    notes: "Email unverified – may need follow-up via phone.",
    last_activity_at: 6.days.ago
  },
  {
    owner_entity: "Forest Lane Properties LLC",
    human_owner_name: "James Okonkwo", owner_title: "Managing Member",
    owner_email: "james@forestlaneproperties.com", owner_phone: "214-555-0412",
    owner_linkedin: "linkedin.com/in/james-okonkwo-dallas",
    org_domain: "forestlaneproperties.com", enrichment_source: "apollo",
    email_verified: true, status: "enriched", deal_status: "in_negotiation",
    notes: "Replied asking for insurance adjuster coordination contact. Very interested.",
    last_activity_at: 1.day.ago
  },
  {
    owner_entity: "Harry Hines Medical Properties LP",
    human_owner_name: "Carolyn Bautista", owner_title: "Asset Manager",
    owner_email: "cbautista@hhmedicalprop.com", owner_phone: "214-555-0673",
    owner_linkedin: "linkedin.com/in/carolynbautista-realty",
    org_domain: "hhmedicalprop.com", enrichment_source: "apollo",
    email_verified: true, status: "enriched", deal_status: "prospecting",
    notes: nil,
    last_activity_at: 7.days.ago
  },
  {
    owner_entity: "Inwood Industrial Group LLC",
    human_owner_name: "Greg Hartfield", owner_title: "President",
    owner_email: "ghartfield@inwoodig.com", owner_phone: "972-555-0154",
    owner_linkedin: nil,
    org_domain: "inwoodig.com", enrichment_source: "secretary_of_state",
    email_verified: true, status: "enriched", deal_status: "prospecting",
    notes: "Not yet emailed – report still generating.",
    last_activity_at: nil
  },
  {
    owner_entity: "Greenville Ave Capital Partners",
    human_owner_name: "Michelle Torres", owner_title: "Co-Founder & Partner",
    owner_email: "mtorres@greenvillecp.com", owner_phone: "214-555-0845",
    owner_linkedin: "linkedin.com/in/michelle-torres-dallas-re",
    org_domain: "greenvillecp.com", enrichment_source: "linkedin",
    email_verified: true, status: "enriched", deal_status: "lost",
    notes: "Already under contract with another roofing company. Mark do not contact.",
    last_activity_at: 3.days.ago
  }
]

contacts = contacts_data.map do |attrs|
  c = Contact.find_or_initialize_by(
    storm_event: storm,
    owner_entity: attrs[:owner_entity]
  )
  c.assign_attributes(attrs)
  c.save!
  puts "  Contact: #{c.human_owner_name} (#{c.owner_entity}) – #{c.deal_status}"
  c
end

# ─────────────────────────────────────────────
# 4. GAMMA REPORTS (completed for emailed properties)
# ─────────────────────────────────────────────
gamma_report_data = [
  { idx: 0, report_id: "rpt_dallas_maple_001",     gamma_url: "https://gamma.app/docs/maple-properties-hail-assessment-2026", credits_used: 3, status: "completed" },
  { idx: 1, report_id: "rpt_dallas_stemmons_002",  gamma_url: "https://gamma.app/docs/stemmons-industrial-hail-report-2026",  credits_used: 3, status: "completed" },
  { idx: 2, report_id: "rpt_dallas_oaklawn_003",   gamma_url: "https://gamma.app/docs/oak-lawn-ventures-hail-damage-2026",    credits_used: 3, status: "completed" },
  { idx: 3, report_id: "rpt_dallas_market_004",    gamma_url: "https://gamma.app/docs/market-center-realty-hail-2026",        credits_used: 3, status: "completed" },
  { idx: 4, report_id: "rpt_dallas_lbj_005",       gamma_url: "https://gamma.app/docs/lbj-office-partners-hail-2026",        credits_used: 3, status: "completed" },
  { idx: 5, report_id: "rpt_dallas_commerce_006",  gamma_url: "https://gamma.app/docs/commerce-street-holdings-hail-2026",   credits_used: 3, status: "completed" },
  { idx: 6, report_id: "rpt_dallas_forest_007",    gamma_url: "https://gamma.app/docs/forest-lane-properties-hail-2026",     credits_used: 3, status: "completed" },
  { idx: 9, report_id: "rpt_dallas_greenville_010",gamma_url: "https://gamma.app/docs/greenville-ave-capital-hail-2026",     credits_used: 3, status: "completed" }
]

gamma_reports = {}
gamma_report_data.each do |g|
  prop = properties[g[:idx]]
  report = GammaReport.find_or_initialize_by(property: prop)
  report.assign_attributes(
    report_id:    g[:report_id],
    gamma_url:    g[:gamma_url],
    credits_used: g[:credits_used],
    status:       g[:status]
  )
  report.save!
  gamma_reports[g[:idx]] = report
  puts "  GammaReport: #{prop.address}"
end

# ─────────────────────────────────────────────
# 5. EMAIL OUTREACHES + CAMPAIGNS (engagement variety)
# ─────────────────────────────────────────────

# engagement_level: :replied, :clicked, :opened, :delivered, :sent
outreach_scenarios = [
  # [property_idx, contact_idx, engagement_level, followup_day]
  [0, 0, :replied,   0],   # Maple – Derek Fontaine – replied
  [1, 1, :opened,    0],   # Stemmons – Patricia Ng – opened x2 (no reply)
  [2, 2, :replied,   0],   # Oak Lawn – Marcus Delgado – replied (WON)
  [3, 3, :delivered, 0],   # Market Center – Sandra Okafor – delivered, no open
  [4, 4, :clicked,   0],   # LBJ – Robert Yuen – clicked report
  [5, 5, :delivered, 0],   # Commerce – Tanya Williamson – delivered
  [6, 6, :replied,   0],   # Forest Lane – James Okonkwo – replied
  [9, 9, :opened,    0],   # Greenville – Michelle Torres – opened, lost
  # Follow-ups
  [0, 0, :opened,    3],   # Maple – day-3 follow-up opened
  [1, 1, :delivered, 3],   # Stemmons – day-3 delivered
]

outreach_scenarios.each do |(p_idx, c_idx, engagement, followup_day)|
  prop    = properties[p_idx]
  contact = contacts[c_idx]
  gamma   = gamma_reports[p_idx]

  subject = followup_day == 0 ?
    "#{prop.address} – Hail Damage Assessment (Mar 3 Storm)" :
    "Following up – #{prop.address} roof inspection"

  body = followup_day == 0 ?
    "Hi #{contact.human_owner_name.split.first},\n\nI'm reaching out because the March 3rd hailstorm dropped 2-inch hail directly over your property at #{prop.address}. We've prepared a complimentary damage assessment report for you.\n\nWould you be open to a quick call this week?\n\nBest,\nAmy" :
    "Hi #{contact.human_owner_name.split.first},\n\nJust following up on my earlier note about hail damage at #{prop.address}. Happy to coordinate with your insurance adjuster.\n\nBest,\nAmy"

  sent_at = (7 - followup_day).days.ago + followup_day.days

  outreach = EmailOutreach.find_or_initialize_by(
    property:     prop,
    contact:      contact,
    followup_day: followup_day
  )
  outreach.assign_attributes(
    gamma_report:   gamma,
    subject:        subject,
    body:           body,
    sent_to_email:  contact.owner_email,
    status:         "sent",
    sent_at:        sent_at
  )
  outreach.save!

  # Email campaign tracking record
  campaign = EmailCampaign.find_or_initialize_by(email_outreach: outreach)
  campaign_attrs = {
    owner_name:  contact.human_owner_name,
    address:     prop.address,
    variant:     %w[a b c d].sample,
    delivered_at: sent_at + 2.minutes,
    status:      "delivered"
  }

  case engagement
  when :replied
    campaign_attrs.merge!(
      opened_at:  sent_at + rand(1..4).hours,
      clicked_at: gamma ? sent_at + rand(2..5).hours : nil,
      replied_at: sent_at + rand(3..8).hours,
      status:     "replied"
    )
  when :clicked
    campaign_attrs.merge!(
      opened_at:  sent_at + rand(1..3).hours,
      clicked_at: sent_at + rand(2..6).hours,
      status:     "clicked"
    )
  when :opened
    campaign_attrs.merge!(
      opened_at: sent_at + rand(1..5).hours,
      status:    "opened"
    )
  when :delivered
    # no open – just delivered
  end

  campaign.assign_attributes(campaign_attrs)
  campaign.save!

  puts "  Outreach: #{contact.human_owner_name} → #{prop.address} [#{engagement}, day #{followup_day}]"
end

# ─────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────
puts ""
puts "Dallas demo seed complete!"
puts "  Storm events : #{StormEvent.count}"
puts "  Properties   : #{Property.count}"
puts "  Contacts     : #{Contact.count}"
puts "  Gamma reports: #{GammaReport.count}"
puts "  Outreaches   : #{EmailOutreach.count}"
puts "  Campaigns    : #{EmailCampaign.count}"
puts ""
puts "Dashboard: /pipeline"
puts "CRM view : /contacts"

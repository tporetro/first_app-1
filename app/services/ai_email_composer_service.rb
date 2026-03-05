require 'anthropic'

# AI-powered email composer using Claude Opus 4.6.
# Writes fully personalized outreach — no templates, genuine reasoning
# about each owner's specific role, property exposure, and storm context.
#
# The goal: be the first outreach they receive that reads like a human
# who actually understands their situation.
class AiEmailComposerService
  MODEL = :"claude-opus-4-6"

  SYSTEM_PROMPT = <<~SYSTEM.freeze
    You are Michael Johnson, Director of Commercial Services at Restoration GC —
    an Austin-based general contractor specializing in large-loss commercial storm damage claims.

    Restoration GC's team includes licensed engineers, certified public adjusters, and insurance
    attorneys. We handle the entire claim process: forensic inspection → engineering report →
    PA-managed claim presentation → legal support if carrier disputes → restoration execution.
    Property owners pay nothing out of pocket until the claim is approved and funded.

    You write cold outreach emails to commercial property owners and portfolio managers after
    hail storms. Your audience is sophisticated — they manage large industrial/commercial portfolios
    and get cold email constantly. What cuts through is specificity, credibility, and a clear
    financial stake.

    Your emails are:
    - SHORT (150 words max in the body — they will not read more)
    - Specific: exact address, exact hail size, exact storm date, exact dollar exposure
    - Credible: you mention the engineering + PA + legal team — not just "roofing contractor"
    - Urgent but factual: insurance filing deadlines are real; you state them, you don't manufacture them
    - Conversational: no "I hope this finds you well", no "please don't hesitate", no passive voice
    - One ask: click the report link. Not "call us", not "let's discuss" — read the report first.

    Close with: Amy on our team will reach out to schedule a 20-minute call. CC: amy@restorationgc.net
    Signature: Michael Johnson | (512) 621-4201 | michael@restorationgc.net

    Output ONLY the plain-text email body. Start with "Hi [FirstName]," — no subject line, no headers.
  SYSTEM

  # Returns { subject:, body:, variant: } or raises on error.
  def self.compose(lead:, report_url:, variant: 'a')
    client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

    user_prompt = build_prompt(lead, report_url, variant)

    message = client.messages.create(
      model: MODEL,
      max_tokens: 512,
      thinking: { type: 'adaptive' },
      system: SYSTEM_PROMPT,
      messages: [{ role: 'user', content: user_prompt }]
    )

    body = extract_text(message)
    subject = compose_subject(lead, variant)

    { subject: subject, body: body, variant: variant }
  rescue StandardError => e
    Rails.logger.error "AI email composition failed: #{e.message}"
    # Fall back to Resend template-based email
    raise
  end

  # ---------------------------------------------------------------------------
  # Intelligent follow-up composer
  #
  # Claude reads the full engagement history and reasons about what to write —
  # not a template. Each follow-up is different based on:
  #   - Which day it is (3 / 7 / 14 / 21)
  #   - Whether they opened the initial email
  #   - Whether they clicked the report link
  #   - Whether they've already received prior follow-ups
  #   - The original subject line and property context
  #
  # After Day 3, the CTA shifts from "read the report" to "book a call."
  # ---------------------------------------------------------------------------
  FOLLOWUP_SYSTEM_PROMPT = <<~SYSTEM.freeze
    You are Amy, scheduling coordinator at Restoration GC — an Austin-based commercial storm
    damage contractor with licensed engineers, certified public adjusters, and insurance attorneys.

    Michael Johnson sent the initial outreach. Your job is to follow up on his behalf.
    Your emails are:
    - SHORT (100 words max — shorter than the initial email)
    - Conversational and human — not corporate
    - Adapted to the contact's behavior: if they opened, acknowledge the report exists without
      saying you know they opened it. If they clicked, the value is proven — push toward a call.
      If they haven't engaged at all, try a completely different angle or question.
    - One clear ask per email: either read the report OR book a call (not both)
    - Never mention "just following up" or "circling back" — those are banned phrases

    Signature: Amy | Restoration GC | amy@restorationgc.net | CC: michael@restorationgc.net

    Output ONLY the plain-text email body. Start with "Hi [FirstName],"
  SYSTEM

  # engagement: { opened: bool, clicked: bool, open_count: int, prior_followups: int }
  def self.compose_followup(lead:, report_url:, day:, engagement:, variant: 'a')
    client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

    prompt  = build_followup_prompt(lead, report_url, day, engagement)
    message = client.messages.create(
      model:      MODEL,
      max_tokens: 400,
      thinking:   { type: 'adaptive' },
      system:     FOLLOWUP_SYSTEM_PROMPT,
      messages:   [{ role: 'user', content: prompt }]
    )

    body    = extract_text(message)
    subject = compose_followup_subject(lead, day, engagement, variant)

    { subject: subject, body: body, variant: variant }
  rescue StandardError => e
    Rails.logger.error "Followup composition failed (Day #{day}): #{e.message}"
    raise
  end

  private_class_method def self.build_followup_prompt(lead, report_url, day, engagement)
    first_name     = lead[:human_owner_name]&.split&.first || 'there'
    company        = lead[:parent_company] || lead[:owner_entity]
    hail_size      = lead[:hail_size]
    storm_date     = lead[:storm_date]
    claim_deadline = lead[:claim_deadline]
    property_count = lead[:property_count] || 1
    total_recovery = lead[:total_recovery]
    calendly_url   = ENV['CALENDLY_URL'] || 'https://calendly.com/restorationgc/20min'

    opened       = engagement[:opened]
    clicked      = engagement[:clicked]
    open_count   = engagement[:open_count].to_i
    prior_count  = engagement[:prior_followups].to_i

    # Describe engagement honestly for Claude's reasoning
    engagement_desc = if clicked
      "The contact CLICKED the report link — they engaged with the content. High intent signal."
    elsif opened && open_count >= 2
      "The contact opened the email #{open_count} times but has not clicked the report. Clearly interested but may need a nudge."
    elsif opened
      "The contact opened the email once but did not click the report link."
    else
      "The contact has not opened the email. The initial email and #{prior_count} prior follow-up(s) got no engagement."
    end

    # Define the strategic goal for Claude
    strategy = if clicked
      "They clicked the report. The next step is booking a call. Make it easy and low-commitment — 20 minutes, no pitch, just to walk them through the findings. Use this Calendly link: #{calendly_url}"
    elsif day >= 14
      "This is a late-stage follow-up. Be direct. The filing window closes #{claim_deadline}. Offer the Calendly link as a low-friction option: #{calendly_url}. This may be the last touchpoint."
    elsif day == 7 && opened
      "They looked but didn't act. Try a different angle — ask a question about the property or their current insurance situation. Don't just resend the report link; make them want to respond."
    elsif !opened && prior_count >= 1
      "No engagement at all after #{prior_count} attempts. Try a completely different subject line angle. Consider asking a single question to elicit a reply rather than pushing the report."
    else
      "Reinforce the value of the report. The ask is: click the link and read it. Keep it very short. #{report_url}"
    end

    property_context = property_count > 1 ?
      "#{property_count} properties, total estimated recovery #{total_recovery}" :
      "#{lead[:address]}, #{lead[:county]} County"

    <<~PROMPT
      Write a follow-up email. This is Day #{day} of the Amy follow-up cadence.

      RECIPIENT: #{first_name}#{company.present? ? ", #{company}" : ''}
      STORM: #{hail_size}" hail on #{storm_date}
      PROPERTY: #{property_context}
      FILING DEADLINE: #{claim_deadline}
      REPORT: #{report_url}

      ENGAGEMENT HISTORY: #{engagement_desc}

      STRATEGIC GOAL FOR THIS EMAIL: #{strategy}

      CONSTRAINTS:
      - 100 words max
      - Never say "just following up", "circling back", "hope this finds you well"
      - One ask only
      - Human and direct
    PROMPT
  end

  private_class_method def self.compose_followup_subject(lead, day, engagement, variant)
    first_name     = lead[:human_owner_name]&.split&.first
    claim_deadline = lead[:claim_deadline]
    property_count = lead[:property_count] || 1
    total_recovery = lead[:total_recovery]
    hail_size      = lead[:hail_size]

    if engagement[:clicked]
      "#{first_name ? "#{first_name} — " : ''}Ready to walk through the findings?"
    elsif engagement[:opened] && day <= 7
      "#{first_name ? "#{first_name}: " : ''}One question about #{lead[:address] || 'your property'}"
    elsif day >= 14
      "Filing deadline: #{claim_deadline} — #{property_count > 1 ? lead[:owner_entity] : lead[:address]}"
    elsif day == 21
      property_count > 1 ?
        "#{total_recovery} — final notice before claim window closes" :
        "Last notice: #{lead[:address]} claim window closes #{claim_deadline}"
    else
      # Rotate subject angles by variant + day to avoid repetition
      angles = [
        "Re: #{lead[:address] || lead[:owner_entity]}",
        "#{hail_size}\" storm — #{first_name ? "#{first_name}, " : ''}did you see the report?",
        "Quick question about your #{property_count > 1 ? 'portfolio' : 'property'}",
        "#{first_name}: #{claim_deadline} filing deadline"
      ]
      angles[(day + variant.ord) % angles.size]
    end
  end

  # Batch compose for multiple leads using Claude's Batches API to reduce cost.
  # Returns array of { lead:, subject:, body:, variant: }.
  def self.batch_compose(leads_with_variants:, report_urls:)
    client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

    requests = leads_with_variants.map.with_index do |(lead, variant), idx|
      report_url = report_urls[lead[:property_id]] || '#'
      {
        custom_id: "lead-#{idx}-#{lead[:property_id]}",
        params: {
          model: MODEL,
          max_tokens: 512,
          thinking: { type: 'adaptive' },
          system: SYSTEM_PROMPT,
          messages: [{ role: 'user', content: build_prompt(lead, report_url, variant) }]
        }
      }
    end

    batch = client.messages.batches.create(requests: requests)
    Rails.logger.info "Batch #{batch.id} submitted with #{requests.size} requests"

    # Poll until complete
    result_batch = poll_batch(client, batch.id)

    # Map results back to leads
    results = []
    leads_with_variants.each.with_index do |(lead, variant), idx|
      custom_id = "lead-#{idx}-#{lead[:property_id]}"
      item = result_batch.find { |r| r.custom_id == custom_id }
      next unless item&.result&.type == 'succeeded'

      body = extract_text(item.result.message)
      results << {
        lead: lead,
        subject: compose_subject(lead, variant),
        body: body,
        variant: variant
      }
    end
    results
  end

  private

  def self.build_prompt(lead, report_url, variant)
    first_name      = lead[:human_owner_name]&.split&.first || 'there'
    title           = lead[:owner_title]
    company         = lead[:owner_entity] || lead[:parent_company]
    hail_size       = lead[:hail_size]
    storm_date      = lead[:storm_date]
    claim_deadline  = lead[:claim_deadline]
    property_count  = lead[:property_count] || 1
    total_recovery  = lead[:total_recovery]
    research        = lead[:research] || {}

    # Build context block
    if property_count > 1
      property_context = "PORTFOLIO: #{property_count} properties affected. Total estimated recovery: #{total_recovery}."
    else
      sq_ft    = lead[:sq_ft]
      recovery = sq_ft ? ReportTemplateService.fmt_dollars((sq_ft * ReportTemplateService::COST_PER_SQFT).to_i) : nil
      property_context = "PROPERTY: #{lead[:address]}, #{lead[:county]} County. #{sq_ft ? "#{sq_ft.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} sq ft." : ''} #{recovery ? "Estimated recovery: #{recovery}." : ''}"
    end

    role_line = [title, company].compact.join(' at ')

    research_hook = research[:hook].present? ? "Prospect research hook to naturally weave in (optional): #{research[:hook]}" : ''
    company_ctx   = research[:company_context].present? ? "Company context: #{research[:company_context]}" : ''

    variant_angle = case variant.to_s
                    when 'a' then "Lead with the intelligence report — they have findings waiting for them."
                    when 'b' then "Lead with the dollar exposure — #{total_recovery || 'seven figures'} at risk if undocumented."
                    when 'c' then "Lead with the filing deadline — #{claim_deadline || 'time is running out'}."
                    when 'd' then "Lead with hidden damage — most property owners don't know they have it."
                    else "Lead with the intelligence report."
                    end

    <<~PROMPT
      Write a cold outreach email. Be specific. Be short. Make them want to click.

      RECIPIENT: #{first_name}#{role_line.present? ? ", #{role_line}" : ''}
      STORM: #{hail_size}-inch hail on #{storm_date}
      #{property_context}
      FILING DEADLINE: #{claim_deadline || 'within 12 months of storm date'}
      REPORT LINK: #{report_url}

      #{company_ctx}
      #{research_hook}

      ANGLE FOR THIS EMAIL: #{variant_angle}

      IMPORTANT:
      - Mention our team includes engineers, public adjusters, and insurance attorneys — not just roofing
      - No payment until claim is approved and funded
      - The ask is: click the report link. That's it.
      - 150 words max
    PROMPT
  end

  def self.compose_subject(lead, variant)
    first_name     = lead[:human_owner_name]&.split&.first
    address        = lead[:address]
    storm_date     = lead[:storm_date]
    property_count = lead[:property_count] || 1
    total_recovery = lead[:total_recovery]
    claim_deadline = lead[:claim_deadline]

    if property_count > 1
      # Portfolio subject lines
      case variant.to_s
      when 'a' then "Confidential: #{property_count}-Property Damage Intelligence Brief — #{lead[:owner_entity]}"
      when 'b' then "#{total_recovery} in Undocumented Hail Exposure — #{lead[:owner_entity]} Portfolio"
      when 'c' then "#{lead[:owner_entity]}: #{property_count} Properties | Filing Window Closes #{claim_deadline}"
      when 'd' then "#{first_name}: Your #{property_count} DFW Properties Were in the #{lead[:hail_size]}\" Hail Swath"
      else "Confidential: Portfolio Damage Intelligence Brief — #{lead[:owner_entity]}"
      end
    else
      # Single-property subject lines
      case variant.to_s
      when 'a' then "Confidential: Damage Intelligence Report — #{address}"
      when 'b' then "#{address}: #{ReportTemplateService.fmt_dollars(((lead[:sq_ft] || 50_000) * ReportTemplateService::COST_PER_SQFT).to_i)} Hail Exposure"
      when 'c' then "Filing Window Closes #{claim_deadline} — #{address}"
      when 'd' then "#{first_name}: #{address} Was in the #{lead[:hail_size]}\" Hail Swath (#{storm_date})"
      else "Confidential: Storm Damage Report — #{address}"
      end
    end
  end

  def self.extract_text(message)
    message.content
      .select { |block| block.type == 'text' }
      .map(&:text)
      .join("\n")
      .strip
  end

  def self.poll_batch(client, batch_id, timeout: 600)
    deadline = Time.now + timeout
    loop do
      raise 'Batch polling timed out' if Time.now > deadline

      batch = client.messages.batches.retrieve(batch_id)
      break batch if batch.processing_status == 'ended'

      Rails.logger.info "Batch #{batch_id} in progress: #{batch.request_counts.processing} remaining"
      sleep 15
    end

    # Collect results
    results = []
    client.messages.batches.results(batch_id).each { |r| results << r }
    results
  end
end

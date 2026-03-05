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

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
    You are Michael Johnson, Director of Commercial Services at Restoration GC,
    a commercial roofing and storm damage restoration company.

    You write cold outreach emails to commercial property owners after hail storms.
    Your emails are:
    - Concise (under 200 words in the body)
    - Specific to the person's role and company context
    - Urgent but not alarmist — you present forensic facts, not scare tactics
    - Conversational — no corporate jargon, no filler phrases like "I hope this email finds you well"
    - Focused on ONE thing: getting them to click the report link

    You NEVER mention competitors, NEVER use superlatives, and NEVER make promises
    you cannot keep. You always CC amy@restorationgc.net and note she will follow up
    to schedule a call.

    Output ONLY the email body (no subject line, no headers). Start directly with "Hi [FirstName],"
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
    first_name   = lead[:human_owner_name]&.split&.first || 'there'
    title        = lead[:owner_title]
    company      = lead[:owner_entity] || lead[:parent_company]
    address      = lead[:address]
    county       = lead[:county]
    hail_size    = lead[:hail_size]
    storm_date   = lead[:storm_date]
    sq_ft        = lead[:sq_ft]
    property_type = lead[:property_type] || 'commercial property'

    role_context = if title && company
                     "They are #{title} of #{company}."
                   else
                     "They own a commercial property."
                   end

    sq_ft_context = sq_ft ? "The property is #{sq_ft.to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1,').reverse} sq ft." : ''

    variant_angle = case variant.to_s
                    when 'a' then 'Lead with the forensic report and what it reveals.'
                    when 'b' then 'Lead with the financial risk and insurance claim opportunity.'
                    when 'c' then 'Lead with urgency — carrier documentation deadlines are real.'
                    when 'd' then 'Lead with the fact that most commercial owners don\'t know they have damage yet.'
                    else 'Lead with the forensic report.'
                    end

    <<~PROMPT
      Write a cold outreach email for this specific situation:

      Recipient first name: #{first_name}
      Role context: #{role_context}
      Property: #{address}, #{county} County (#{property_type})
      #{sq_ft_context}
      Storm: #{hail_size}-inch hail on #{storm_date}
      Report link: #{report_url}

      Email angle: #{variant_angle}

      Remember: Amy (CC'd) will follow up to schedule a 20-minute call.
      Michael's phone: (512) 621-4201
    PROMPT
  end

  def self.compose_subject(lead, variant)
    first_name = lead[:human_owner_name]&.split&.first
    address    = lead[:address]
    date       = lead[:storm_date]

    case variant.to_s
    when 'a' then "Confidential: Storm Damage Intelligence Report — #{address}"
    when 'b' then "#{address} — Hidden Hail Damage Risk (#{date})"
    when 'c' then "Urgent: #{date} Storm Claim Window Closing — #{address}"
    when 'd' then "#{first_name}: Your #{address} Was in the Hail Swath"
    else "Confidential: Storm Damage Report — #{address}"
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

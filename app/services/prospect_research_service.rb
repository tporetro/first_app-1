require 'anthropic'

# Uses Claude with web search to research a prospect before email composition.
# The richer the context going in, the more personal the email coming out.
#
# Researches: company news, owner LinkedIn activity, property portfolio,
# recent acquisitions, public statements — anything that makes the email
# feel like it came from someone who did their homework.
class ProspectResearchService
  MODEL = :"claude-opus-4-6"

  # Returns a research summary hash with keys:
  #   :company_context, :owner_context, :portfolio_context, :hook
  def self.research(lead:)
    client = Anthropic::Client.new(api_key: ENV['ANTHROPIC_API_KEY'])

    prompt = build_research_prompt(lead)

    # Use Claude with web search to investigate the prospect
    message = client.messages.create(
      model: MODEL,
      max_tokens: 1024,
      thinking: { type: 'adaptive' },
      tools: [
        { type: 'web_search_20260209', name: 'web_search' }
      ],
      system: <<~SYSTEM,
        You are a research analyst preparing a briefing on a commercial property owner
        so that an outreach email can be personalized for maximum impact.

        Research the prospect using web search. Focus on:
        1. Recent company news, expansions, or transactions
        2. The owner's professional background and priorities
        3. The property portfolio size and investment focus
        4. Any recent LinkedIn posts, press releases, or interviews

        Be concise. Return only verified, specific facts — no speculation.
        Format your response as JSON with keys: company_context, owner_context, portfolio_context, hook.
        "hook" is a 1-sentence observation that could open the email naturally.
      SYSTEM
      messages: [{ role: 'user', content: prompt }]
    )

    parse_research(message)
  rescue StandardError => e
    Rails.logger.error "Prospect research failed for #{lead[:owner_entity]}: #{e.message}"
    default_research(lead)
  end

  private

  def self.build_research_prompt(lead)
    <<~PROMPT
      Research this commercial property owner:

      Company: #{lead[:owner_entity]}
      #{lead[:parent_company] ? "Parent company: #{lead[:parent_company]}" : ''}
      Owner: #{lead[:human_owner_name]} (#{lead[:owner_title]})
      Domain: #{lead[:org_domain]}
      LinkedIn: #{lead[:owner_linkedin]}
      Property: #{lead[:address]}, #{lead[:city]}, #{lead[:state]}

      Search for recent news, the owner's LinkedIn activity, portfolio information,
      and anything that would help personalize an outreach email about storm damage
      to their #{lead[:address]} property.
    PROMPT
  end

  def self.parse_research(message)
    text = message.content
      .select { |b| b.type == 'text' }
      .map(&:text)
      .join

    # Extract JSON from response
    json_match = text.match(/\{[\s\S]*\}/)
    return default_research({}) unless json_match

    JSON.parse(json_match[0], symbolize_names: true)
  rescue JSON::ParserError
    { company_context: text, owner_context: '', portfolio_context: '', hook: '' }
  end

  def self.default_research(lead)
    {
      company_context: "#{lead[:owner_entity]} is a commercial property owner.",
      owner_context: lead[:owner_title] || '',
      portfolio_context: '',
      hook: ''
    }
  end
end

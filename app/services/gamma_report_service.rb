require 'net/http'
require 'uri'
require 'json'

# Phase 4 — Gamma Report Generation via Gamma public API.
# Submits markdown, polls until complete, returns gamma_url.
# Rate: 2s delay between submissions. Cost: ~400 credits per 20-card report.
class GammaReportService
  API_BASE     = 'https://public-api.gamma.app/v1.0'.freeze
  POLL_INTERVAL = 15  # seconds between status checks
  POLL_TIMEOUT  = 300 # 5 minutes max

  THEME_ID   = 'consultant'.freeze
  NUM_CARDS  = 20
  IMAGE_MODEL = 'recraft-v3-svg'.freeze

  def self.generate(markdown_content:)
    api_key = ENV['GAMMA_API_KEY']
    raise 'GAMMA_API_KEY not set' unless api_key

    gen_id = submit_generation(markdown_content, api_key)
    return nil unless gen_id

    poll_for_completion(gen_id, api_key)
  end

  private

  def self.submit_generation(markdown, api_key)
    payload = {
      inputText:  markdown,
      textMode:   'generate',
      format:     'presentation',
      themeId:    THEME_ID,
      numCards:   NUM_CARDS,
      cardSplit:  'auto',
      textOptions: {
        amount:   'detailed',
        tone:     'Urgent, forensic, professional',
        audience: 'Corporate acquisitions team and senior asset managers',
        language: 'en'
      },
      imageOptions: {
        source: 'aiGenerated',
        model:  IMAGE_MODEL,
        style:  'illustration'
      }
    }

    response = post_json("#{API_BASE}/generations", payload, api_key)
    response&.dig('generationId')
  end

  def self.poll_for_completion(gen_id, api_key)
    deadline = Time.now + POLL_TIMEOUT

    while Time.now < deadline
      sleep POLL_INTERVAL
      status = get_json("#{API_BASE}/generations/#{gen_id}", api_key)
      next unless status

      case status['status']
      when 'completed'
        return status['gammaUrl']
      when 'failed'
        Rails.logger.error "Gamma generation #{gen_id} failed: #{status['error']}"
        return nil
      end
    end

    Rails.logger.error "Gamma generation #{gen_id} timed out after #{POLL_TIMEOUT}s"
    nil
  end

  def self.post_json(url, payload, api_key)
    uri  = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri.path)
    req['Content-Type'] = 'application/json'
    req['X-API-KEY']    = api_key
    req['accept']       = 'application/json'
    req.body = payload.to_json
    resp = http.request(req)
    JSON.parse(resp.body) if resp.is_a?(Net::HTTPSuccess)
  end

  def self.get_json(url, api_key)
    uri  = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Get.new(uri.path)
    req['X-API-KEY'] = api_key
    req['accept']    = 'application/json'
    resp = http.request(req)
    JSON.parse(resp.body) if resp.is_a?(Net::HTTPSuccess)
  end
end

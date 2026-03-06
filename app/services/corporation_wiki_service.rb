require 'nokogiri'
require 'net/http'
require 'uri'

# Free company officer lookup via CorporationWiki.com (no API key required).
#
# What it finds:
#   - CEO / Managing Member / President / Registered Agent names + titles
#   - State of incorporation
#
# Strategy:
#   1. Search corporationwiki.com for the entity name (+ state to narrow results)
#   2. Pick the top result whose name closely matches owner_entity
#   3. Fetch the company detail page and extract officers
#   4. Return the most senior officer as the likely decision-maker
class CorporationWikiService
  BASE_URL = 'https://www.corporationwiki.com'.freeze
  TIMEOUT  = 15 # seconds

  HEADERS = {
    'User-Agent'      => 'Mozilla/5.0 (compatible; research-bot/1.0)',
    'Accept'          => 'text/html,application/xhtml+xml',
    'Accept-Language' => 'en-US,en;q=0.9'
  }.freeze

  Result = Struct.new(:human_owner_name, :owner_title, keyword_init: true)

  # Returns a Result or nil. Never raises.
  def self.lookup(owner_entity:, state: nil)
    query  = [owner_entity.to_s.strip, state].compact.join(' ')
    search_doc = fetch_html("/search/results?q=#{URI.encode_www_form_component(query)}")
    return nil unless search_doc

    company_path = best_match_path(search_doc, owner_entity)
    return nil unless company_path

    company_doc = fetch_html(company_path)
    return nil unless company_doc

    extract_officer(company_doc)
  rescue StandardError => e
    Rails.logger.error "CorporationWikiService error for #{owner_entity}: #{e.message}"
    nil
  end

  private

  # Pick the first search result whose name fuzzy-matches owner_entity.
  # CorporationWiki search result links look like /p/12345/company-name
  def self.best_match_path(doc, owner_entity)
    normalized = owner_entity.downcase.gsub(/[^a-z0-9]/, '')

    doc.css('a[href*="/p/"]').each do |link|
      href = link['href']
      next unless href.match?(%r{/p/\d+/})

      link_text = link.text.strip.downcase.gsub(/[^a-z0-9]/, '')
      return href if link_text.include?(normalized) || normalized.include?(link_text[0, 8])
    end

    # Fall back to first result
    first = doc.at_css('a[href*="/p/"]')
    first&.[]('href')
  end

  # Title priority — we want the most senior decision-maker
  TITLE_PRIORITY = %w[
    ceo president founder owner principal
    managing\ member manager member director officer agent
  ].freeze

  def self.extract_officer(doc)
    officers = []

    # CorporationWiki renders officers in a table or list with name + title cells
    doc.css('.officer, .person-row, tr').each do |row|
      name  = row.at_css('.name, .officer-name, td:first-child')&.text&.strip
      title = row.at_css('.title, .officer-title, td:nth-child(2)')&.text&.strip
      officers << { name: name, title: title } if name.present? && name.length > 2
    end

    # Also try definition-list style markup
    if officers.empty?
      doc.css('dt, .label').each_with_index do |dt, _|
        next unless dt.text =~ /officer|agent|member|director|president|manager/i
        name = dt.next_element&.text&.strip
        officers << { name: name, title: dt.text.strip } if name.present?
      end
    end

    return nil if officers.empty?

    best = officers.min_by do |o|
      t = o[:title].to_s.downcase
      TITLE_PRIORITY.index { |p| t.include?(p) } || 99
    end

    Result.new(human_owner_name: best[:name], owner_title: best[:title].presence)
  end

  def self.fetch_html(path)
    url  = path.start_with?('http') ? path : "#{BASE_URL}#{path}"
    uri  = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl     = (uri.scheme == 'https')
    http.read_timeout = TIMEOUT

    req = Net::HTTP::Get.new(uri.request_uri, HEADERS)
    resp = http.request(req)

    unless resp.is_a?(Net::HTTPSuccess)
      Rails.logger.debug "CorporationWiki #{path} → #{resp.code}"
      return nil
    end

    Nokogiri::HTML(resp.body)
  rescue StandardError => e
    Rails.logger.warn "CorporationWiki fetch failed (#{path}): #{e.message}"
    nil
  end
end

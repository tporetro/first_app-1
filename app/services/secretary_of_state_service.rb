require 'nokogiri'
require 'net/http'
require 'uri'

# Free Secretary of State business record lookup.
# Scrapes state SoS websites directly — no API key, no cost.
#
# Returns the registered agent or principal officer behind an LLC/corp —
# the human name we can use for contact enrichment.
#
# Supported states: AR, FL, TX, OK, TN, GA, NC, AL, MS, LA, MO
class SecretaryOfStateService
  TIMEOUT = 20

  HEADERS = {
    'User-Agent'      => 'Mozilla/5.0 (compatible; research-bot/1.0)',
    'Accept'          => 'text/html,application/xhtml+xml',
    'Accept-Language' => 'en-US,en;q=0.9'
  }.freeze

  Result = Struct.new(:human_owner_name, :owner_title, keyword_init: true)

  def self.lookup(owner_entity:, state:)
    case state.to_s.upcase
    when 'AR' then arkansas(owner_entity)
    when 'FL' then florida(owner_entity)
    when 'GA' then georgia(owner_entity)
    when 'NC' then north_carolina(owner_entity)
    when 'TN' then tennessee(owner_entity)
    when 'AL' then alabama(owner_entity)
    when 'MS' then mississippi(owner_entity)
    when 'LA' then louisiana(owner_entity)
    when 'MO' then missouri(owner_entity)
    else
      Rails.logger.debug "SoS: no scraper for state #{state}"
      nil
    end
  rescue StandardError => e
    Rails.logger.warn "SoS #{state} lookup failed for #{owner_entity}: #{e.message}"
    nil
  end

  private

  # ---------------------------------------------------------------------------
  # Arkansas — LLC member info is confidential per AR Act 865 of 2007.
  # Only registered agent (often a law firm) is public. Not useful for contact enrichment.
  # ---------------------------------------------------------------------------
  def self.arkansas(_entity)
    nil
  end

  # ---------------------------------------------------------------------------
  # Florida — https://search.sunbiz.org (most reliable SoS in the US)
  # ---------------------------------------------------------------------------
  def self.florida(entity)
    encoded = URI.encode_www_form_component(entity)
    doc = fetch_html("https://search.sunbiz.org/Inquiry/CorporationSearch/SearchResults?inquiryType=EntityName&inquiryDirectionType=ForwardList&searchNameOrder=#{encoded}&activeOnly=true")
    return nil unless doc

    link = best_match_link(doc, entity, 'a[href*="CorporationSearch/GetPage"]')
    return nil unless link

    detail_url = link.start_with?('http') ? link : "https://search.sunbiz.org#{link}"
    detail = fetch_html(detail_url)
    return nil unless detail

    officers = []
    detail.css('span.officers p, div.officers p').each do |p|
      lines = p.text.strip.split("\n").map(&:strip).reject(&:blank?)
      next if lines.size < 2
      officers << { name: lines[1], title: lines[0] }
    end
    # fallback: section label rows
    if officers.empty?
      detail.css('label').each do |label|
        next unless label.text.match?(/officer|director|agent|member|manager|president|registered/i)
        name = label.next_sibling&.text&.strip
        officers << { name: name, title: label.text.strip } if name.present? && name.length > 2
      end
    end
    best_officer(officers)
  end

  # ---------------------------------------------------------------------------
  # Georgia — https://ecorp.sos.ga.gov/
  # ---------------------------------------------------------------------------
  def self.georgia(entity)
    encoded = URI.encode_www_form_component(entity)
    doc = fetch_html("https://ecorp.sos.ga.gov/BusinessSearch?businessName=#{encoded}&businessType=&businessStatus=Active&county=&registeredAgentName=&principalName=&UBINumber=&myGovSearch=false&businessNameSearch=true")
    return nil unless doc

    link = best_match_link(doc, entity, 'a[href*="BusinessInformation"]')
    return nil unless link

    detail_url = link.start_with?('http') ? link : "https://ecorp.sos.ga.gov#{link}"
    detail = fetch_html(detail_url)
    return nil unless detail

    officers = []
    detail.css('table tr').each do |row|
      cells = row.css('td').map { |td| td.text.strip }
      next if cells.size < 2
      officers << { name: cells[1], title: cells[0] } if cells[1].present? && cells[1].length > 2
    end
    best_officer(officers)
  end

  # ---------------------------------------------------------------------------
  # North Carolina — https://www.sosnc.gov/online_services/search/by_title/_Business_Registration
  # ---------------------------------------------------------------------------
  def self.north_carolina(entity)
    encoded = URI.encode_www_form_component(entity)
    doc = fetch_html("https://www.sosnc.gov/online_services/search/by_title/_Business_Registration?name=#{encoded}&status=Active")
    return nil unless doc

    link = best_match_link(doc, entity, 'a[href*="business_registration_profile"]')
    return nil unless link

    detail_url = link.start_with?('http') ? link : "https://www.sosnc.gov#{link}"
    detail = fetch_html(detail_url)
    return nil unless detail

    extract_generic_officers(detail)
  end

  # ---------------------------------------------------------------------------
  # Tennessee — https://tnbear.tn.gov/ECommerce/FilingSearch.aspx
  # ---------------------------------------------------------------------------
  def self.tennessee(entity)
    encoded = URI.encode_www_form_component(entity)
    doc = fetch_html("https://tnbear.tn.gov/ECommerce/FilingSearch.aspx?searchText=#{encoded}&searchType=entityName")
    return nil unless doc

    link = best_match_link(doc, entity, 'a[href*="FilingDetail"]')
    return nil unless link

    detail_url = link.start_with?('http') ? link : "https://tnbear.tn.gov#{link}"
    detail = fetch_html(detail_url)
    return nil unless detail

    extract_generic_officers(detail)
  end

  # ---------------------------------------------------------------------------
  # Alabama — https://arc-sos.state.al.us/CGI/corpdetail.mbr/detail
  # ---------------------------------------------------------------------------
  def self.alabama(entity)
    encoded = URI.encode_www_form_component(entity)
    doc = fetch_html("https://arc-sos.state.al.us/CGI/corpname.mbr/output?name=#{encoded}&status=ALL&type=ALL&agent=")
    return nil unless doc

    link = best_match_link(doc, entity, 'a[href*="corpdetail"]')
    return nil unless link

    detail_url = link.start_with?('http') ? link : "https://arc-sos.state.al.us#{link}"
    detail = fetch_html(detail_url)
    return nil unless detail

    extract_generic_officers(detail)
  end

  # ---------------------------------------------------------------------------
  # Mississippi — https://corp.sos.ms.gov/corp/portal/c/page/corpSearch/portal.aspx
  # ---------------------------------------------------------------------------
  def self.mississippi(entity)
    # MS uses a complex ASP.NET form — not easily scrapable without session handling
    nil
  end

  # ---------------------------------------------------------------------------
  # Louisiana — https://coraweb.sos.la.gov/commercialsearch/commercialsearch.aspx
  # ---------------------------------------------------------------------------
  def self.louisiana(entity)
    # LA also uses ASP.NET ViewState — skip for now
    nil
  end

  # ---------------------------------------------------------------------------
  # Missouri — https://bsd.sos.mo.gov/BusinessEntity/BESearch.aspx
  # ---------------------------------------------------------------------------
  def self.missouri(entity)
    encoded = URI.encode_www_form_component(entity)
    doc = fetch_html("https://bsd.sos.mo.gov/BusinessEntity/BESearch.aspx?SearchType=0&SearchValue=#{encoded}")
    return nil unless doc

    link = best_match_link(doc, entity, 'a[href*="BESearch.aspx?id="]')
    return nil unless link

    detail_url = link.start_with?('http') ? link : "https://bsd.sos.mo.gov#{link}"
    detail = fetch_html(detail_url)
    return nil unless detail

    extract_generic_officers(detail)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  TITLE_PRIORITY = %w[
    ceo president founder owner principal
    managing\ member manager member director officer agent organizer
  ].freeze

  def self.best_officer(officers)
    return nil if officers.empty?
    best = officers.min_by do |o|
      t = o[:title].to_s.downcase
      TITLE_PRIORITY.index { |p| t.include?(p) } || 99
    end
    Result.new(human_owner_name: best[:name], owner_title: best[:title])
  end

  def self.extract_generic_officers(doc)
    officers = []
    doc.css('table tr').each do |row|
      cells = row.css('td').map { |td| td.text.strip }
      next if cells.size < 2
      title, name = cells[0], cells[1]
      next unless name.present? && name.length > 2
      next unless title.match?(/agent|officer|member|manager|president|director|organizer|principal/i)
      officers << { name: name, title: title }
    end
    best_officer(officers)
  end

  def self.best_match_link(doc, entity, css_selector)
    normalized = entity.downcase.gsub(/[^a-z0-9]/, '')
    doc.css(css_selector).each do |a|
      text = a.text.strip.downcase.gsub(/[^a-z0-9]/, '')
      return a['href'] if text.include?(normalized) || normalized.include?(text[0, 8])
    end
    doc.at_css(css_selector)&.[]('href')
  end

  def self.fetch_html(url)
    uri  = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl      = (uri.scheme == 'https')
    http.read_timeout = TIMEOUT
    req  = Net::HTTP::Get.new(uri.request_uri, HEADERS)
    resp = http.request(req)
    return nil unless resp.is_a?(Net::HTTPSuccess)
    Nokogiri::HTML(resp.body)
  rescue StandardError => e
    Rails.logger.warn "SoS fetch failed (#{url}): #{e.message}"
    nil
  end
end

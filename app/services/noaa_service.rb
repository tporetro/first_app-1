require 'net/http'
require 'uri'

# Phase 1 — Storm Detection
# Checks NOAA SPC hail reports for events >= 1.5" in target metro areas.
# Reference: https://www.spc.noaa.gov/climo/reports/today_hail.html
class NoaaService
  SPC_YESTERDAY_URL  = 'https://www.spc.noaa.gov/climo/reports/yesterday_hail.html'.freeze
  SPC_TODAY_URL      = 'https://www.spc.noaa.gov/climo/reports/today_hail.html'.freeze
  MIN_HAIL_SIZE      = 1.5  # inches

  TARGET_STATES = %w[TX OK KS CO NE MO AR LA MS AL GA TN NC SC IN MI].freeze

  # Returns array of storm hashes: { date, hail_size, location, counties, state }
  # Filters to events with hail >= MIN_HAIL_SIZE in TARGET_STATES.
  def self.fetch_recent_hail(date: :yesterday)
    url = date == :today ? SPC_TODAY_URL : SPC_YESTERDAY_URL
    html = fetch_html(url)
    return [] unless html

    parse_hail_reports(html)
      .select { |r| r[:hail_size] >= MIN_HAIL_SIZE && TARGET_STATES.include?(r[:state]) }
  end

  private

  def self.fetch_html(url)
    uri = URI.parse(url)
    response = Net::HTTP.get_response(uri)
    response.body if response.is_a?(Net::HTTPSuccess)
  rescue StandardError => e
    Rails.logger.error "NOAA fetch error: #{e.message}"
    nil
  end

  # Parse NOAA SPC HTML report table rows.
  # Handles two formats:
  #
  # Format A — SPC CSV (embedded in HTML):
  #   Time,F-Scale,Speed,Size,Location,County,State,Lat,Lon,Comments
  #   e.g. 1912,0,0,1.75,SUNNYVALE,DALLAS,TX,32.79,-96.56,...
  #
  # Format B — NWS semicolon-delimited county list (from alert emails / NWS products):
  #   "Dallas, TX; Ellis, TX; Kaufman, TX"
  #   Used when Clawbot receives NWS alerts rather than parsing SPC CSV directly.
  #
  def self.parse_hail_reports(html)
    reports = []

    # Format A: SPC CSV rows
    html.scan(/(\d{4}),\d+,(\d+\.\d+|\d+),[\d.]+,([^,]+),([^,]+),([A-Z]{2}),/) do |_time, size, location, county, state|
      reports << {
        date:      Date.today.to_s,
        hail_size: size.to_f,
        location:  "#{location.strip}, #{state}",
        counties:  [county.strip],
        state:     state.strip
      }
    end

    # Format B: NWS "County, ST; County, ST" alert strings embedded anywhere in the HTML
    # e.g. "Dallas, TX; Ellis, TX; Kaufman, TX"
    # Group consecutive county entries for the same state into one storm report.
    nws_matches = html.scan(/([A-Z][a-zA-Z\s]+),\s*([A-Z]{2})(?:\s*;)?/)
                      .map { |county, state| { county: county.strip, state: state.strip } }
                      .select { |m| TARGET_STATES.include?(m[:state]) }

    unless nws_matches.empty?
      # Group by state for a single event; extract hail size from nearby context
      by_state = nws_matches.group_by { |m| m[:state] }
      by_state.each do |state, entries|
        # Try to find hail size in the surrounding text (e.g. "1.50 INCH HAIL", "1.75\"")
        size_match = html.match(/(\d+\.\d+)\s*(?:inch|in\b|")/i)
        hail_size  = size_match ? size_match[1].to_f : MIN_HAIL_SIZE

        next if hail_size < MIN_HAIL_SIZE

        counties = entries.map { |e| e[:county] }.uniq
        reports << {
          date:      Date.today.to_s,
          hail_size: hail_size,
          location:  "#{counties.first}, #{state}",
          counties:  counties,
          state:     state
        }
      end
    end

    reports
  end
end

require 'net/http'
require 'uri'

# Phase 1 — Storm Detection
# Checks NOAA SPC hail reports for events >= 1.5" in target metro areas.
# Reference: https://www.spc.noaa.gov/climo/reports/today_hail.html
class NoaaService
  SPC_YESTERDAY_URL  = 'https://www.spc.noaa.gov/climo/reports/yesterday_hail.html'.freeze
  SPC_TODAY_URL      = 'https://www.spc.noaa.gov/climo/reports/today_hail.html'.freeze
  MIN_HAIL_SIZE      = 1.5  # inches

  TARGET_STATES = %w[TX OK KS CO NE MO AR LA MS AL GA TN NC SC].freeze

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
  # SPC CSV format: Time,F-Scale,Speed,Size,Location,County,State,Lat,Lon,Comments
  def self.parse_hail_reports(html)
    reports = []
    # SPC embeds hail data in a CSV block or table; extract size/state/county lines.
    # This regex targets CSV-formatted hail report lines.
    html.scan(/(\d{4}),\d+,(\d+\.\d+|\d+),[\d.]+,([^,]+),([^,]+),([A-Z]{2}),/) do |_time, size, location, county, state|
      reports << {
        date:     Date.today.to_s,
        hail_size: size.to_f,
        location: "#{location.strip}, #{state}",
        counties: [county.strip],
        state:    state.strip
      }
    end
    reports
  end
end

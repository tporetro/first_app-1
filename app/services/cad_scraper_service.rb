require 'net/http'
require 'uri'
require 'csv'
require 'zip'

# Phase 2 — CAD Bulk Property Fetcher
#
# Downloads bulk property export files from Texas County Appraisal Districts (CADs)
# and returns commercial property records for use by MapsOfMeaningService.
#
# Each TX county CAD publishes annual data extracts at predictable URLs.
# We download the accounts/buildings CSV, filter by commercial land use code,
# and return normalized property hashes.
#
# Supported counties (expand REGISTRY as needed):
#   Dallas (DCAD), Harris (HCAD), Tarrant, Collin, Denton, Travis, Bexar,
#   Fort Bend, Williamson, Montgomery, Brazoria, Ellis, Kaufman, Rockwall,
#   Johnson, Parker, Wise, Hood, Somervell
#
# Usage:
#   records = CadScraperService.fetch_commercial_properties(county: 'Dallas', state: 'TX')
#   # => [{ address:, city:, county:, state_abbr:, state_code:, sq_ft:, owner_entity:, lat:, lon: }, ...]
#
class CadScraperService
  # ---------------------------------------------------------------------------
  # CAD Registry — one entry per county
  # Each entry describes how to download and parse that CAD's bulk export.
  # ---------------------------------------------------------------------------
  REGISTRY = {
    # Dallas County — DCAD
    # Full export: https://www.dallascad.org/AcctDetailRes.aspx  (account search)
    # Bulk CSV:    https://www.dallascad.org/downloads/  (select "Real Property" or "Personal")
    'Dallas' => {
      state:    'TX',
      adapter:  :dcad,
      urls: {
        real:     'https://www.dallascad.org/downloads/real_acct_owner.zip',
        personal: 'https://www.dallascad.org/downloads/pers_acct_owner.zip'
      }
    },

    # Harris County — HCAD
    # Bulk data portal: https://downloads.hcad.org/
    'Harris' => {
      state:   'TX',
      adapter: :hcad,
      urls: {
        building: 'https://downloads.hcad.org/data/CAMA/#{year}/building_other.zip',
        account:  'https://downloads.hcad.org/data/CAMA/#{year}/real_acct_owner.zip'
      }
    },

    # Tarrant County — TAD
    'Tarrant' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.tad.org/download/real_acct.zip'
      }
    },

    # Collin County — CCAD
    'Collin' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.collincad.org/downloads/real_acct.zip'
      }
    },

    # Denton County — DCAD (Denton)
    'Denton' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.dentoncad.com/downloads/real_acct.zip'
      }
    },

    # Ellis County — ECAD
    'Ellis' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.elliscad.com/downloads/real_acct.zip'
      }
    },

    # Kaufman County — KCAD
    'Kaufman' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.kaufmancad.org/downloads/real_acct.zip'
      }
    },

    # Travis County — TCAD (Austin)
    'Travis' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://www.traviscad.org/downloads/real_acct.zip'
      }
    },

    # Bexar County — BCAD (San Antonio)
    'Bexar' => {
      state:   'TX',
      adapter: :generic_csv,
      urls: {
        real: 'https://bexar.trueautomation.com/clientdb/downloads/real_acct.zip'
      }
    }
  }.freeze

  # Texas state property category codes we want to pull
  COMMERCIAL_CODES = %w[F1 F2 L1 L2 B1 B2 B3 B4 X1 X2 X3 X4 X5 X6].freeze

  # Temporary download directory
  TMP_DIR = Rails.root.join('tmp', 'cad_downloads').freeze

  # ---------------------------------------------------------------------------
  # Entry point
  # ---------------------------------------------------------------------------
  # Returns array of normalized property hashes:
  #   { address:, city:, county:, state_abbr:, state_code:, sq_ft:,
  #     owner_entity:, lat:, lon: }
  #
  def self.fetch_commercial_properties(county:, state: 'TX')
    config = REGISTRY[county]
    unless config
      log "No CAD registry entry for #{county}, #{state} — skipping"
      return []
    end

    FileUtils.mkdir_p(TMP_DIR)

    records = case config[:adapter]
              when :dcad  then fetch_dcad(county, config)
              when :hcad  then fetch_hcad(county, config)
              else             fetch_generic_csv(county, config)
              end

    log "CadScraper: #{records.size} commercial records from #{county} County"
    records
  rescue StandardError => e
    log "CadScraper error for #{county}: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
    []
  end

  # ---------------------------------------------------------------------------
  # DCAD adapter (Dallas County)
  # ---------------------------------------------------------------------------
  # DCAD real_acct_owner.csv columns (pipe-delimited):
  #   acct_num | owner_name | addr1 | addr2 | city | zip | state_code | land_sqft | bldg_sqft | ...
  # (Actual column layout varies by export year; map by header name)
  #
  def self.fetch_dcad(county, config)
    records = []

    config[:urls].each do |type, url|
      csv_path = download_and_extract(url, county, type.to_s)
      next unless csv_path

      CSV.foreach(csv_path, headers: true, col_sep: detect_delimiter(csv_path),
                             encoding: 'ISO-8859-1:UTF-8', liberal_parsing: true) do |row|
        next unless COMMERCIAL_CODES.include?(row['state_cd']&.strip ||
                                              row['state_code']&.strip ||
                                              row['prop_type_cd']&.strip)

        sq_ft = (row['bldg_sqft'] || row['impr_sqft'] || row['tot_sqft'] || '0').to_f

        records << {
          address:      clean([row['situs_num'], row['situs_street'], row['situs_street_sfx']].compact.join(' ')),
          city:         clean(row['situs_city'] || row['city']),
          county:       county,
          state_abbr:   'TX',
          state_code:   clean(row['state_cd'] || row['state_code'] || row['prop_type_cd']),
          sq_ft:        sq_ft,
          owner_entity: clean(row['owner_name'] || row['agent_name']),
          lat:          row['lat']&.to_f,
          lon:          row['lon']&.to_f || row['lng']&.to_f
        }
      end
    end

    records.uniq { |r| r[:address] }
  end

  # ---------------------------------------------------------------------------
  # HCAD adapter (Harris County / Houston)
  # ---------------------------------------------------------------------------
  # HCAD uses a year-based URL pattern and tab-delimited TXT files inside the ZIP.
  #
  def self.fetch_hcad(county, config)
    year = Date.today.year.to_s
    records = []

    config[:urls].each do |type, url_template|
      url = url_template.gsub('#{year}', year)
      csv_path = download_and_extract(url, county, type.to_s)
      next unless csv_path

      CSV.foreach(csv_path, headers: true, col_sep: "\t",
                             encoding: 'ISO-8859-1:UTF-8', liberal_parsing: true) do |row|
        next unless COMMERCIAL_CODES.include?(row['state_class']&.strip ||
                                              row['property_type']&.strip)

        records << {
          address:      clean([row['site_addr_1'], row['site_addr_2']].compact.join(' ')),
          city:         clean(row['site_addr_3'] || 'Houston'),
          county:       'Harris',
          state_abbr:   'TX',
          state_code:   clean(row['state_class'] || row['property_type']),
          sq_ft:        (row['building_sqft'] || row['gross_area'] || '0').to_f,
          owner_entity: clean(row['owner_name']),
          lat:          row['latitude']&.to_f,
          lon:          row['longitude']&.to_f
        }
      end
    end

    records.uniq { |r| r[:address] }
  end

  # ---------------------------------------------------------------------------
  # Generic CSV adapter (most other TX CADs via TrueAutomation)
  # ---------------------------------------------------------------------------
  # TrueAutomation-hosted CADs (Tarrant, Collin, Denton, Ellis, Kaufman, Travis, Bexar, etc.)
  # share a similar schema: pipe or comma delimited, consistent header names.
  #
  def self.fetch_generic_csv(county, config)
    records = []

    config[:urls].each do |type, url|
      csv_path = download_and_extract(url, county, type.to_s)
      next unless csv_path

      CSV.foreach(csv_path, headers: true, col_sep: detect_delimiter(csv_path),
                             encoding: 'ISO-8859-1:UTF-8', liberal_parsing: true) do |row|
        state_code = clean(row['state_cd'] || row['state_code'] || row['prop_type_cd'] ||
                           row['property_use_cd'] || row['cat_code'])
        next unless COMMERCIAL_CODES.include?(state_code)

        sq_ft = (row['bldg_sqft'] || row['impr_sqft'] || row['building_sqft'] ||
                 row['gross_sqft'] || '0').to_f

        records << {
          address:      build_address(row),
          city:         clean(row['situs_city'] || row['city'] || row['site_city']),
          county:       county,
          state_abbr:   'TX',
          state_code:   state_code,
          sq_ft:        sq_ft,
          owner_entity: clean(row['owner_name'] || row['agent_name'] || row['dba_name']),
          lat:          (row['lat'] || row['latitude'])&.to_f,
          lon:          (row['lon'] || row['lng'] || row['longitude'])&.to_f
        }
      end
    end

    records.uniq { |r| r[:address] }
  end

  # ---------------------------------------------------------------------------
  # Download + extract ZIP → returns path to first CSV/TXT file found
  # ---------------------------------------------------------------------------
  def self.download_and_extract(url, county, label)
    zip_path = TMP_DIR.join("#{county.downcase}_#{label}_#{Date.today}.zip")

    # Use cached file if downloaded today
    unless File.exist?(zip_path) && File.mtime(zip_path) > Time.now - 12.hours
      log "Downloading #{label} data from #{url}"
      download_file(url, zip_path)
    end

    return nil unless File.exist?(zip_path)

    extract_dir = TMP_DIR.join("#{county.downcase}_#{label}_extracted")
    FileUtils.mkdir_p(extract_dir)

    Zip::File.open(zip_path) do |zip|
      zip.each do |entry|
        next unless entry.name =~ /\.(csv|txt|dat)\z/i
        dest = extract_dir.join(File.basename(entry.name))
        entry.extract(dest) { true }  # overwrite
      end
    end

    # Return path to the largest CSV/TXT in the extract dir (main data file)
    Dir[extract_dir.join('*')].select { |f| f =~ /\.(csv|txt|dat)\z/i }
                               .max_by { |f| File.size(f) }

  rescue Zip::Error => e
    log "ZIP extraction failed for #{county}/#{label}: #{e.message}"
    nil
  end

  # ---------------------------------------------------------------------------
  # HTTP download with redirect following
  # ---------------------------------------------------------------------------
  def self.download_file(url, dest_path)
    uri = URI.parse(url)
    redirects = 0

    loop do
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                      read_timeout: 120, open_timeout: 30) do |http|
        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = 'Mozilla/5.0 (RestorationGC-Clawbot/1.0)'

        http.request(request) do |response|
          case response
          when Net::HTTPSuccess
            File.open(dest_path, 'wb') { |f| response.read_body { |chunk| f.write(chunk) } }
            return dest_path
          when Net::HTTPRedirection
            raise 'Too many redirects' if (redirects += 1) > 5
            uri = URI.parse(response['location'])
          else
            log "HTTP #{response.code} fetching #{url}"
            return nil
          end
        end
      end
    end
  rescue StandardError => e
    log "Download error for #{url}: #{e.message}"
    nil
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def self.build_address(row)
    num    = row['situs_num']   || row['site_addr_num']  || row['house_num']   || ''
    street = row['situs_street']|| row['site_addr_str']  || row['street_name'] || ''
    sfx    = row['situs_street_sfx'] || row['street_sfx'] || ''
    clean([num, street, sfx].map(&:to_s).map(&:strip).reject(&:empty?).join(' '))
  end

  def self.detect_delimiter(path)
    first_line = File.open(path, 'r:ISO-8859-1') { |f| f.readline rescue '' }
    pipes      = first_line.count('|')
    tabs       = first_line.count("\t")
    commas     = first_line.count(',')

    if pipes > commas && pipes > tabs
      '|'
    elsif tabs > commas
      "\t"
    else
      ','
    end
  rescue
    ','
  end

  def self.clean(val)
    val.to_s.strip.presence
  end

  def self.log(msg)
    timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
    Rails.logger.info "[#{timestamp}] CadScraper: #{msg}"
    puts "[#{timestamp}] CadScraper: #{msg}"
  end
end

require 'net/http'
require 'json'
require 'uri'
require 'time'
require 'zlib'
require 'stringio'
require_relative 'reference_job_matcher'

# Single-batch pipeline for the RGV/McAllen reference-street campaign:
#   fetch up to BATCH_SIZE unworked leads -> enrichment gate -> do-not-call gate
#   -> match against the active jobs list -> push matched leads to Retell -> stop.
#
# Processes exactly one batch per call and returns — by design, not looped. The
# campaign owner reviews each batch's results and explicitly asks for the next one
# rather than this running unattended through the whole list.
#
# Unmatched (but enriched, DNC-clear) leads are tagged for the standard script and
# are NOT called from this runner — per the matching spec, a reference-street claim
# never goes out without a real nearby job to back it.
#
# Required env vars: SUPABASE_URL, SUPABASE_KEY (publishable/anon key — RLS is
# currently disabled on this project, see docs/campaigns/rgv-mcallen; do not point
# this at a project where that key can't already read/write `leads`), RETELL_API_KEY.
class ReferenceStreetCampaignRunner
  BATCH_SIZE = 100
  MATCH_RADIUS_MILES = 6.0
  CALL_THROTTLE_SECONDS = 3
  FROM_NUMBER = '+19569487327' # Alex - RGV McAllen Retell number
  CALLING_HOURS_LOCAL = (9...18) # 9am-6pm, naive local-hours gate — see run_batches!

  def initialize(supabase_url: ENV.fetch('SUPABASE_URL'),
                  supabase_key: ENV.fetch('SUPABASE_KEY'),
                  retell_api_key: ENV.fetch('RETELL_API_KEY', nil),
                  matcher: ReferenceJobMatcher.new,
                  dry_run: false)
    @supabase_url = supabase_url.chomp('/')
    @supabase_key = supabase_key
    @retell_api_key = retell_api_key
    @matcher = matcher
    @dry_run = dry_run
  end

  # Processes exactly one batch of up to BATCH_SIZE leads, then returns — call this
  # again (a fresh invocation) for the next batch once you've reviewed the results.
  # allow_outside_hours: true bypasses the calling-hours gate (for dry runs/tests only).
  def run_batches!(allow_outside_hours: false)
    unless allow_outside_hours || @dry_run || calling_hours?
      puts '[campaign] Outside calling hours window, not dialing this run.'
      return
    end

    dnc = fetch_do_not_call_set
    @dialed_phones = fetch_already_dialed_phones
    puts "[campaign] DRY RUN — no writes to Supabase, no calls placed via Retell.\n\n" if @dry_run

    total = { dialed: 0, standard_hail_hook: 0, do_not_call: 0, enrichment_incomplete: 0, duplicate_phone: 0 }
    batch = fetch_batch
    if batch.empty?
      puts '[campaign] No eligible leads. Done.'
      return total
    end

    batch.each { |lead| total[process_lead(lead, dnc)] += 1 }
    puts "[campaign] Processed batch of #{batch.size}."
    puts "[campaign] Summary: #{total}"
    puts '[campaign] Batch complete — run again for the next 100 when ready.' unless @dry_run
    total
  end

  private

  def calling_hours?
    original_tz = ENV['TZ']
    ENV['TZ'] = 'America/Chicago' # DST-aware via system tzdata, unlike a fixed UTC offset
    CALLING_HOURS_LOCAL.cover?(Time.now.hour)
  ensure
    ENV['TZ'] = original_tz
  end

  # Returns a symbol describing the outcome: :dialed, :standard_hail_hook,
  # :do_not_call, :duplicate_phone, or :enrichment_incomplete.
  def process_lead(lead, dnc)
    unless enriched?(lead)
      log(lead, 'enrichment_incomplete — missing property/lat-lng/phone')
      patch_lead(lead['lead_id'], call_status: 'enrichment_incomplete')
      return :enrichment_incomplete
    end

    phone = normalize_phone(lead['contact_phone'])

    if dnc.include?(phone)
      log(lead, 'do_not_call — phone matches do_not_call table')
      patch_lead(lead['lead_id'], call_status: 'do_not_call')
      return :do_not_call
    end

    # Multiple lead rows can share one contact_phone (e.g. repeat hail-event entries
    # for the same property) — only ever dial a given number once per campaign,
    # regardless of how many lead rows it appears on or which batch they land in.
    if @dialed_phones.include?(phone)
      log(lead, 'duplicate_phone — already dialed this phone number')
      patch_lead(lead['lead_id'], call_status: 'duplicate_phone')
      return :duplicate_phone
    end

    job = @matcher.match(lat: lead['lat'], lng: lead['lng'], radius_miles: MATCH_RADIUS_MILES)

    if job.nil?
      log(lead, 'standard_hail_hook — no active job within radius')
      # call_status must leave 'pending' here too, or fetch_batch's is-null/is-pending
      # filter keeps re-matching this lead forever since no call ever gets placed for it.
      patch_lead(lead['lead_id'], hook_path_used: 'standard_hail_hook', call_status: 'routed_standard_script')
      return :standard_hail_hook
    end

    log(lead, "dialed — matched job #{job.job_id} (#{job.reference_street}), would call #{lead['contact_phone']}")
    patch_lead(
      lead['lead_id'],
      reference_job_location: job.reference_street,
      reference_job_scope: 'insurance-funded roof replacement',
      hook_path_used: 'rgv_mcallen_reference_street'
    )

    call_id = place_call(lead, job)
    @dialed_phones << phone # must happen before the next lead is processed, in case it shares this phone

    patch_lead(
      lead['lead_id'],
      retell_call_id: call_id,
      call_status: 'dialed',
      called_at: Time.now.utc.iso8601
    )

    sleep CALL_THROTTLE_SECONDS unless @dry_run
    :dialed
  end

  def log(lead, message)
    prefix = @dry_run ? '[dry-run]' : '[campaign]'
    puts "#{prefix} lead #{lead['lead_id']} (#{lead['address']}): #{message}"
  end

  def enriched?(lead)
    lead['property_id'] && lead['lat'] && lead['lng'] && !lead['contact_phone'].to_s.empty?
  end

  def normalize_phone(phone)
    phone.to_s.gsub(/\D/, '').sub(/\A1(\d{10})\z/, '\1')
  end

  STATE_ABBREVIATIONS = %w[TX MN].to_set

  # Addresses are "street, city, state" when city was captured, but some rows are
  # only "street, state" — falls back to county so {{city}} never renders as "TX".
  def city_from_address(address, county_fallback)
    parts = address.to_s.split(',').map(&:strip)
    candidate = parts[1]
    return candidate if candidate && !STATE_ABBREVIATIONS.include?(candidate.upcase)

    county_fallback
  end

  def first_name_from(contact_name)
    contact_name.to_s.split(' ').first
  end

  def place_call(lead, job)
    return 'dry_run_no_call' if @dry_run

    uri = URI('https://api.retellai.com/v2/create-phone-call')
    body = {
      from_number: FROM_NUMBER,
      to_number: lead['contact_phone'],
      retell_llm_dynamic_variables: {
        first_name: first_name_from(lead['contact_name']),
        address_raw_best: lead['address'],
        city: city_from_address(lead['address'], lead['county']),
        state: lead['state'],
        call_attempt: '1',
        reference_street: job.reference_street
      }
    }

    response = post_json(uri, body, @retell_api_key)
    JSON.parse(response.body)['call_id']
  end

  def fetch_batch
    uri = URI("#{@supabase_url}/rest/v1/leads_for_matching")
    uri.query = URI.encode_www_form(
      call_status: 'eq.pending',
      retell_call_id: 'is.null',
      limit: BATCH_SIZE
    )
    JSON.parse(decoded_body(get(uri)))
  end

  def fetch_do_not_call_set
    uri = URI("#{@supabase_url}/rest/v1/do_not_call")
    uri.query = URI.encode_www_form(select: 'phone_e164')
    JSON.parse(decoded_body(get(uri))).map { |row| normalize_phone(row['phone_e164']) }.to_set
  end

  # Every phone number that already has a retell_call_id, from this run or any past one —
  # so re-running the campaign (or resuming after an interruption) never re-dials a number.
  def fetch_already_dialed_phones
    uri = URI("#{@supabase_url}/rest/v1/leads")
    uri.query = URI.encode_www_form(select: 'contact_phone', retell_call_id: 'not.is.null')
    JSON.parse(decoded_body(get(uri))).map { |row| normalize_phone(row['contact_phone']) }.to_set
  end

  def decoded_body(response)
    body = response.body
    return body unless response['content-encoding'] == 'gzip'

    Zlib::GzipReader.new(StringIO.new(body)).read
  end

  def patch_lead(lead_id, attrs)
    return if @dry_run

    uri = URI("#{@supabase_url}/rest/v1/leads")
    uri.query = URI.encode_www_form(id: "eq.#{lead_id}")
    patch_json(uri, attrs, @supabase_key)
  end

  def get(uri)
    req = Net::HTTP::Get.new(uri)
    req['apikey'] = @supabase_key
    req['Authorization'] = "Bearer #{@supabase_key}"
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
  end

  def patch_json(uri, body, supabase_key)
    req = Net::HTTP::Patch.new(uri)
    req['apikey'] = supabase_key
    req['Authorization'] = "Bearer #{supabase_key}"
    req['Content-Type'] = 'application/json'
    req.body = body.to_json
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
  end

  def post_json(uri, body, bearer_key)
    req = Net::HTTP::Post.new(uri)
    req['Authorization'] = "Bearer #{bearer_key}"
    req['Content-Type'] = 'application/json'
    req.body = body.to_json
    Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
  end
end

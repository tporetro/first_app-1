require 'net/http'
require 'json'
require 'uri'
require_relative 'reference_job_matcher'

# Repeating batch pipeline for the RGV/McAllen reference-street campaign:
#   fetch up to BATCH_SIZE unworked leads -> enrichment gate -> do-not-call gate
#   -> match against the active jobs list -> push matched leads to Retell -> repeat.
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
                  retell_api_key: ENV.fetch('RETELL_API_KEY'),
                  matcher: ReferenceJobMatcher.new)
    @supabase_url = supabase_url.chomp('/')
    @supabase_key = supabase_key
    @retell_api_key = retell_api_key
    @matcher = matcher
  end

  # Runs batches of up to BATCH_SIZE until no eligible leads remain.
  # allow_outside_hours: true bypasses the calling-hours gate (for dry runs/tests only).
  def run_batches!(allow_outside_hours: false)
    unless allow_outside_hours || calling_hours?
      puts '[campaign] Outside calling hours window, not dialing this run.'
      return
    end

    dnc = fetch_do_not_call_set
    loop do
      batch = fetch_batch
      break if batch.empty?

      batch.each { |lead| process_lead(lead, dnc) }
      puts "[campaign] Processed batch of #{batch.size}."
    end
    puts '[campaign] No more eligible leads. Done.'
  end

  private

  def calling_hours?
    CALLING_HOURS_LOCAL.cover?(Time.now.getlocal('-06:00').hour) # CST approx; DST not handled
  end

  def process_lead(lead, dnc)
    unless enriched?(lead)
      patch_lead(lead['lead_id'], call_status: 'enrichment_incomplete')
      return
    end

    if dnc.include?(normalize_phone(lead['contact_phone']))
      patch_lead(lead['lead_id'], call_status: 'do_not_call')
      return
    end

    job = @matcher.match(lat: lead['lat'], lng: lead['lng'], radius_miles: MATCH_RADIUS_MILES)

    if job.nil?
      patch_lead(lead['lead_id'], hook_path_used: 'standard_hail_hook')
      return
    end

    patch_lead(
      lead['lead_id'],
      reference_job_location: job.reference_street,
      reference_job_scope: 'insurance-funded roof replacement',
      hook_path_used: 'rgv_mcallen_reference_street'
    )

    call_id = place_call(lead, job)

    patch_lead(
      lead['lead_id'],
      retell_call_id: call_id,
      call_status: 'dialed',
      called_at: Time.now.utc.iso8601
    )

    sleep CALL_THROTTLE_SECONDS
  end

  def enriched?(lead)
    lead['property_id'] && lead['lat'] && lead['lng'] && !lead['contact_phone'].to_s.empty?
  end

  def normalize_phone(phone)
    phone.to_s.gsub(/\D/, '').sub(/\A1(\d{10})\z/, '\1')
  end

  def city_from_address(address)
    parts = address.to_s.split(',').map(&:strip)
    parts[1]
  end

  def first_name_from(contact_name)
    contact_name.to_s.split(' ').first
  end

  def place_call(lead, job)
    uri = URI('https://api.retellai.com/v2/create-phone-call')
    body = {
      from_number: FROM_NUMBER,
      to_number: lead['contact_phone'],
      retell_llm_dynamic_variables: {
        first_name: first_name_from(lead['contact_name']),
        address_raw_best: lead['address'],
        city: city_from_address(lead['address']),
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
    JSON.parse(get(uri).body)
  end

  def fetch_do_not_call_set
    uri = URI("#{@supabase_url}/rest/v1/do_not_call")
    uri.query = URI.encode_www_form(select: 'phone_e164')
    JSON.parse(get(uri).body).map { |row| normalize_phone(row['phone_e164']) }.to_set
  end

  def patch_lead(lead_id, attrs)
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

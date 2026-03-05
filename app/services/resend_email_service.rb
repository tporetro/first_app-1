require 'net/http'
require 'uri'
require 'json'

# Phase 5 — Email Outreach via Resend API.
# Sends personalized storm damage outreach with Gamma report link.
# CC's amy@restorationgc.net for follow-up scheduling.
class ResendEmailService
  API_URL = 'https://api.resend.com/emails'.freeze
  FROM    = 'Michael Johnson <michael@restorationgc.net>'.freeze
  CC      = ['amy@restorationgc.net'].freeze

  SENDER_NAME    = 'Michael Johnson'.freeze
  SENDER_TITLE   = 'Director of Commercial Services'.freeze
  SENDER_COMPANY = 'Restoration GC'.freeze
  SENDER_PHONE   = '(512) 621-4201'.freeze

  # Sends a single outreach email. Returns { success:, message_id:, error: }.
  def self.send_outreach(to:, lead:, report_url:, variant: 'a')
    api_key = ENV['RESEND_API_KEY']
    raise 'RESEND_API_KEY not set' unless api_key

    subject = build_subject(lead, variant)
    html    = build_html(lead, report_url)

    payload = {
      from:    FROM,
      to:      Array(to),
      cc:      CC,
      subject: subject,
      html:    html
    }

    response = post_json(payload, api_key)
    if response && response['id']
      { success: true, message_id: response['id'] }
    else
      { success: false, error: response.inspect }
    end
  rescue StandardError => e
    { success: false, error: e.message }
  end

  # Variant subject lines for A/B/C/D testing (mirrors reference TypeScript analytics)
  SUBJECT_VARIANTS = {
    'a' => 'Confidential: Storm Damage Intelligence Report — %<address>s',
    'b' => 'Urgent: Hidden Hail Damage Risk at %<address>s',
    'c' => 'Forensic Assessment Ready — %<address>s [%<date>s Storm]',
    'd' => '%<owner>s — Your %<address>s Property Was in the Hail Swath'
  }.freeze

  private

  def self.build_subject(lead, variant)
    template = SUBJECT_VARIANTS.fetch(variant.to_s, SUBJECT_VARIANTS['a'])
    format(template,
           address: lead[:address],
           owner:   lead[:human_owner_name]&.split&.first || 'Sir/Madam',
           date:    lead[:storm_date] || Date.today.strftime('%b %-d'))
  end

  def self.build_html(lead, report_url)
    first_name   = lead[:human_owner_name]&.split&.first || 'there'
    hail_size    = lead[:hail_size] || '1.75'
    county       = lead[:county]    || 'your county'
    storm_date   = lead[:storm_date] || 'recently'
    address      = lead[:address]
    title        = lead[:owner_title]
    parent_co    = lead[:parent_company]
    context_line = title && parent_co ? "As #{title} of #{parent_co}, you understand" : "As a commercial property owner, you understand"

    <<~HTML
      <div style="font-family: Arial, sans-serif; max-width: 640px; margin: auto; color: #222;">
        <p>Hi #{first_name},</p>

        <p>On #{storm_date}, a significant hail storm tracking #{hail_size}&rdquo; stones swept through #{county} County, placing
        <strong>#{address}</strong> directly within the documented hail swath.</p>

        <p>#{context_line} that undocumented storm damage represents both a liability concern
        <em>and</em> a strategic capital improvement opportunity — but only when identified before carrier deadlines close.</p>

        <p>Our forensic team has prepared a property-specific damage intelligence report:</p>

        <p style="text-align:center; margin: 32px 0;">
          <a href="#{report_url}"
             style="background-color:#c0392b; color:white; padding:14px 28px;
                    text-decoration:none; border-radius:4px; font-weight:bold; font-size:16px;">
            View Confidential Property Report &rarr;
          </a>
        </p>

        <p>Amy on my team will reach out within 24 hours to schedule a 20-minute call at a time that works for you.
        There is no obligation — just enterprise-grade forensic clarity on your exposure.</p>

        <p>Best regards,</p>
        <p>
          <strong>#{SENDER_NAME}</strong><br>
          #{SENDER_TITLE}<br>
          #{SENDER_COMPANY}<br>
          #{SENDER_PHONE}
        </p>
      </div>
    HTML
  end

  def self.post_json(payload, api_key)
    uri  = URI.parse(API_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    req = Net::HTTP::Post.new(uri.path)
    req['Authorization'] = "Bearer #{api_key}"
    req['Content-Type']  = 'application/json'
    req.body = payload.to_json
    resp = http.request(req)
    JSON.parse(resp.body)
  end
end

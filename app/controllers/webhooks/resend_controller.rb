require 'openssl'

module Webhooks
  # Handles Resend email tracking webhooks: delivered, opened, clicked, complained.
  # Also handles inbound reply detection via Resend's inbound email routing.
  #
  # Configure in Resend dashboard:
  #   Webhook URL: https://yourdomain.com/webhooks/resend
  #   Events: email.delivered, email.opened, email.clicked, email.complained
  #   Signing secret: set RESEND_WEBHOOK_SECRET in ENV
  class ResendController < ApplicationController
    protect_from_forgery except: [:event, :inbound]

    before_action :verify_signature, only: [:event]

    # POST /webhooks/resend
    def event
      payload    = JSON.parse(request.body.read)
      event_type = payload['type']
      data       = payload['data'] || {}
      message_id = data['email_id'] || data['id']

      campaign = EmailCampaign.find_by(mailgun_message_id: message_id)
      return head :ok unless campaign

      contact  = campaign.email_outreach&.contact
      storm_id = campaign.email_outreach&.property&.storm_event_id

      case event_type
      when 'email.delivered'
        campaign.update!(status: 'delivered', delivered_at: Time.now)

      when 'email.opened'
        unless campaign.opened?
          campaign.update!(status: 'opened', opened_at: Time.now)
          contact&.update!(last_activity_at: Time.now)
          VariantOptimizerService.record(variant: campaign.variant, event: :open, storm_event_id: storm_id)
          PushoverService.notify(
            title:   'Email Opened',
            message: "#{campaign.owner_name} opened email for #{campaign.address}"
          )
        end

      when 'email.clicked'
        unless campaign.clicked?
          campaign.update!(status: 'clicked', clicked_at: Time.now)
          contact&.update!(last_activity_at: Time.now)
          VariantOptimizerService.record(variant: campaign.variant, event: :click, storm_event_id: storm_id)
          PushoverService.notify(
            title:   'Report Link Clicked ⚡',
            message: "#{campaign.owner_name} clicked the Gamma report — #{campaign.address}"
          )
        end

      when 'email.complained'
        campaign.update!(status: 'complained')
        # Mark contact as do_not_contact automatically
        contact&.update!(deal_status: 'do_not_contact', last_activity_at: Time.now)
        Rails.logger.warn "Spam complaint from #{campaign.email_outreach&.sent_to_email} — marked do_not_contact"
      end

      head :ok
    rescue StandardError => e
      Rails.logger.error "Resend webhook error: #{e.message}"
      head :ok
    end

    # POST /webhooks/resend/inbound — reply detection
    # Resend inbound routing → POST here when amy@rgcroof.com or michael@rgcroof.com receives a reply
    def inbound
      payload = JSON.parse(request.body.read)
      sender  = payload['from'] || payload['sender']
      subject = payload['subject'] || ''
      snippet = payload['text']&.first(300) || ''

      # Find the most recent outreach sent to this sender
      outreach = EmailOutreach.joins(:contact)
        .where(contacts: { owner_email: sender })
        .where(status: 'sent')
        .order(sent_at: :desc)
        .first

      if outreach&.email_campaign
        campaign = outreach.email_campaign
        contact  = outreach.contact

        # Record the reply signal
        campaign.update!(replied_at: Time.now, status: 'replied')

        # Auto-advance deal status to In Negotiation (unless already further along)
        if %w[prospecting do_not_contact].include?(contact.deal_status)
          contact.update!(deal_status: 'in_negotiation', last_activity_at: Time.now)
        end

        storm_id = outreach.property&.storm_event_id
        VariantOptimizerService.record(
          variant:        campaign.variant,
          event:          :reply,
          storm_event_id: storm_id
        )

        PushoverService.notify(
          title:   '★ REPLY — IN NEGOTIATION',
          message: "#{contact.human_owner_name} (#{contact.owner_entity})\n" \
                   "#{outreach.property.address}\n" \
                   "Subject: #{subject}\n" \
                   "#{snippet.present? ? "\"#{snippet.truncate(120)}\"" : ''}"
        )

        Rails.logger.info "Reply from #{sender} → deal advanced to in_negotiation (contact #{contact.id})"
      end

      head :ok
    rescue StandardError => e
      Rails.logger.error "Resend inbound error: #{e.message}"
      head :ok
    end

    private

    # Verify Resend webhook signature using HMAC-SHA256.
    # Resend sends: svix-id, svix-timestamp, svix-signature headers.
    # Docs: https://resend.com/docs/dashboard/webhooks/introduction#securing-your-webhooks
    def verify_signature
      secret    = ENV['RESEND_WEBHOOK_SECRET']
      return unless secret.present?  # Skip verification if secret not configured

      svix_id        = request.headers['svix-id']
      svix_timestamp = request.headers['svix-timestamp']
      svix_signature = request.headers['svix-signature']

      unless svix_id && svix_timestamp && svix_signature
        Rails.logger.warn "Resend webhook: missing signature headers"
        return head :unauthorized
      end

      # Reconstruct the signed payload
      body          = request.body.read.tap { request.body.rewind }
      signed_content = "#{svix_id}.#{svix_timestamp}.#{body}"

      # The secret is prefixed with "whsec_" — strip it for raw HMAC key
      raw_secret = Base64.decode64(secret.delete_prefix('whsec_'))
      expected   = Base64.strict_encode64(
        OpenSSL::HMAC.digest('SHA256', raw_secret, signed_content)
      )

      # svix-signature may contain multiple space-separated "vN,signature" pairs
      valid = svix_signature.split(' ').any? do |sig_pair|
        _, sig = sig_pair.split(',', 2)
        sig && ActiveSupport::SecurityUtils.secure_compare(sig, expected)
      end

      unless valid
        Rails.logger.warn "Resend webhook: invalid signature — possible spoofed request"
        head :unauthorized
      end
    end
  end
end

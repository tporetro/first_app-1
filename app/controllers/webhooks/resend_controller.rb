module Webhooks
  # Handles Resend email tracking webhooks: delivered, opened, clicked, complained.
  # Also handles inbound reply detection via Resend's inbound email routing.
  #
  # Configure in Resend dashboard:
  #   Webhook URL: https://yourdomain.com/webhooks/resend
  #   Events: email.delivered, email.opened, email.clicked, email.complained
  class ResendController < ApplicationController
    # Resend POSTs webhooks — skip CSRF for this endpoint
    protect_from_forgery except: [:event, :inbound]

    # POST /webhooks/resend
    def event
      payload = JSON.parse(request.body.read)
      event_type = payload['type']                    # e.g. "email.opened"
      data       = payload['data'] || {}
      message_id = data['email_id'] || data['id']

      campaign = EmailCampaign.find_by(mailgun_message_id: message_id)
      return head :ok unless campaign

      storm_id = campaign.email_outreach&.property&.storm_event_id

      case event_type
      when 'email.delivered'
        campaign.update!(status: 'delivered', delivered_at: Time.now)

      when 'email.opened'
        unless campaign.opened?
          campaign.update!(status: 'opened', opened_at: Time.now)
          VariantOptimizerService.record(variant: campaign.variant, event: :open, storm_event_id: storm_id)
          PushoverService.notify(
            title: 'Email Opened',
            message: "#{campaign.owner_name} opened email for #{campaign.address}"
          )
        end

      when 'email.clicked'
        unless campaign.clicked?
          campaign.update!(status: 'clicked', clicked_at: Time.now)
          VariantOptimizerService.record(variant: campaign.variant, event: :click, storm_event_id: storm_id)
          PushoverService.notify(
            title: 'Link Clicked',
            message: "#{campaign.owner_name} clicked the report link for #{campaign.address}"
          )
        end

      when 'email.complained'
        campaign.update!(status: 'complained')
        Rails.logger.warn "Spam complaint from #{campaign.email_outreach&.sent_to_email}"
      end

      head :ok
    rescue StandardError => e
      Rails.logger.error "Resend webhook error: #{e.message}"
      head :ok  # Always 200 so Resend doesn't retry indefinitely
    end

    # POST /webhooks/resend/inbound — reply detection
    # Configure Resend inbound routing to POST here when amy@restorationgc.net receives a reply
    def inbound
      payload = JSON.parse(request.body.read)
      sender  = payload['from'] || payload['sender']
      subject = payload['subject'] || ''

      # Find the campaign by matching sender email to outreach records
      outreach = EmailOutreach.joins(:contact)
        .where(contacts: { owner_email: sender })
        .where(status: 'sent')
        .order(sent_at: :desc)
        .first

      if outreach&.email_campaign
        outreach.email_campaign.update!(replied_at: Time.now, status: 'replied')
        storm_id = outreach.property&.storm_event_id
        VariantOptimizerService.record(
          variant:        outreach.email_campaign.variant,
          event:          :reply,
          storm_event_id: storm_id
        )
        PushoverService.notify(
          title: 'REPLY RECEIVED!',
          message: "#{outreach.contact.human_owner_name} replied about #{outreach.property.address}\nSubject: #{subject}"
        )
      end

      head :ok
    rescue StandardError => e
      Rails.logger.error "Resend inbound error: #{e.message}"
      head :ok
    end
  end
end

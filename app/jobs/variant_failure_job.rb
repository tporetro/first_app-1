# Runs hourly. Marks emails with no open after 48h as variant failures,
# feeding the Thompson Sampling optimizer to shift sends toward winning variants.
class VariantFailureJob
  include Sidekiq::Worker
  sidekiq_options queue: 'pipeline', retry: 0

  def perform
    cutoff = 48.hours.ago
    EmailCampaign
      .where(opened_at: nil, status: 'sent')
      .where('created_at < ?', cutoff)
      .each do |campaign|
        storm_id = campaign.email_outreach&.property&.storm_event_id
        VariantOptimizerService.record_failure(
          variant:        campaign.variant,
          storm_event_id: storm_id
        )
        campaign.update!(status: 'no_open')
      end
  end
end

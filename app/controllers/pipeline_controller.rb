# Lightweight status dashboard — read-only views into the pipeline.
# No authentication layer here; add Devise or HTTP Basic if exposing externally.
class PipelineController < ApplicationController
  def index
    @storms = StormEvent.recent.limit(20)
    @stats  = {
      total_storms:     StormEvent.count,
      total_properties: Property.count,
      total_contacts:   Contact.enriched.count,
      emails_sent:      EmailOutreach.sent.count,
      emails_opened:    EmailCampaign.opened.count,
      emails_clicked:   EmailCampaign.clicked.count,
      emails_replied:   EmailCampaign.replied.count
    }
  end

  def show
    @storm      = StormEvent.find(params[:id])
    @properties = @storm.properties.includes(:gamma_report, :email_outreaches)
    @contacts   = @storm.contacts
    @variants   = VariantOptimizerService.performance_summary(storm_event_id: @storm.id)
  end

  # POST /pipeline/trigger — manual pipeline run (for testing without cron)
  def trigger
    StormPipelineService.run
    redirect_to pipeline_index_path, notice: 'Pipeline triggered. Check logs.'
  end
end

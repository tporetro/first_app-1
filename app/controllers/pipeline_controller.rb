# Lightweight status dashboard — read-only views into the pipeline.
# Authentication handled by ApplicationController (HTTP Basic Auth).
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

  # POST /pipeline/trigger — enqueues a background job rather than running inline.
  # Running StormPipelineService.run synchronously in a request would timeout
  # (pipeline takes 20-40 minutes end-to-end).
  def trigger
    StormMonitorJob.perform_async
    redirect_to pipeline_index_path,
      notice: 'Pipeline job enqueued. Storms will appear here as they are detected and processed.'
  end

  # POST /pipeline/test_run — runs a full end-to-end test, routing email to test_email.
  def test_run
    email = params[:test_email].presence
    return redirect_to(pipeline_index_path, alert: 'test_email param required') unless email

    PipelineTestRunJob.perform_async(email)
    redirect_to pipeline_index_path,
      notice: "Test run enqueued → email will arrive at #{email}. Watch Pushover for phase updates."
  end
end

# Runs every 15 minutes via Sidekiq Cron.
# Checks NOAA SPC for new hail >= 1.5" and triggers the full pipeline
# immediately on detection — before competitors even know the storm happened.
class StormMonitorJob
  include Sidekiq::Worker
  sidekiq_options queue: 'pipeline', retry: 1

  def perform
    StormPipelineService.run
  end
end

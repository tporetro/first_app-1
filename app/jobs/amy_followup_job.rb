# Runs daily at 9 AM CST via Sidekiq Cron.
# Sends Amy-methodology follow-ups at Day 3, 7, 14, 21 post initial outreach.
# Stops automatically when a reply is detected (replied_at set by Resend webhook).
class AmyFollowupJob
  include Sidekiq::Worker
  sidekiq_options queue: 'pipeline', retry: 1

  def perform
    StormPipelineService.run_followups
  end
end

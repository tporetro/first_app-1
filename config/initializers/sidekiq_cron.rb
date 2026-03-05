require 'sidekiq-cron'

# Scheduled jobs for the Storm Lead Pipeline.
# All times relative to server timezone (set TZ=America/Chicago in production).
Sidekiq::Cron::Job.load_from_hash({
  # ── Phase 1: Storm detection ─────────────────────────────────────────────
  # Run every 15 minutes for first-mover advantage.
  # NOAA SPC reports update continuously throughout the day.
  'storm_monitor' => {
    'cron'  => '*/15 * * * *',
    'class' => 'StormMonitorJob',
    'queue' => 'pipeline'
  },

  # ── Amy follow-up cadence ────────────────────────────────────────────────
  # 9 AM CST (15:00 UTC) daily — sends Day 3 / 7 / 14 / 21 follow-ups
  'amy_followups' => {
    'cron'  => '0 15 * * *',
    'class' => 'AmyFollowupJob',
    'queue' => 'pipeline'
  },

  # ── Variant optimizer: score non-opens as failures ───────────────────────
  # Hourly — marks emails with no open after 48h as failures for Thompson Sampling
  'variant_failures' => {
    'cron'  => '0 * * * *',
    'class' => 'VariantFailureJob',
    'queue' => 'pipeline'
  }
})

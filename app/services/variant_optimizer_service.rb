# Adaptive variant assignment using a Thompson Sampling multi-armed bandit.
#
# Instead of rotating A/B/C/D evenly forever, the system learns which subject
# line variants get the best open rates and shifts traffic toward winners —
# while still exploring to catch statistical flukes.
#
# Variants:
#   a — Confidential forensic report angle
#   b — Financial risk / insurance claim angle
#   c — Urgency / carrier deadline angle
#   d — Personalized / "you were in the swath" angle
class VariantOptimizerService
  VARIANTS = %w[a b c d].freeze

  # Returns the best variant to use for the next send, given current performance data.
  # Uses Thompson Sampling: draw from Beta(successes+1, failures+1) for each arm.
  def self.assign(storm_event_id: nil)
    stats = load_stats(storm_event_id)
    samples = VARIANTS.map { |v| [v, thompson_sample(stats[v])] }
    winner = samples.max_by { |_, score| score }.first
    winner
  end

  # Record an outcome for a variant.
  #   event: :open | :click | :reply (hierarchical success signal)
  def self.record(variant:, event:, storm_event_id: nil)
    key = cache_key(storm_event_id)
    stats = Rails.cache.read(key) || fresh_stats
    weight = { open: 1, click: 3, reply: 10 }.fetch(event.to_sym, 1)
    stats[variant.to_s]['successes'] += weight
    Rails.cache.write(key, stats, expires_in: 30.days)
  end

  # Record a failure (email sent but no open within 48h)
  def self.record_failure(variant:, storm_event_id: nil)
    key = cache_key(storm_event_id)
    stats = Rails.cache.read(key) || fresh_stats
    stats[variant.to_s]['failures'] += 1
    Rails.cache.write(key, stats, expires_in: 30.days)
  end

  # Returns performance summary for dashboard display
  def self.performance_summary(storm_event_id: nil)
    stats = load_stats(storm_event_id)
    VARIANTS.map do |v|
      s = stats[v]['successes'].to_f
      f = stats[v]['failures'].to_f
      total = s + f
      {
        variant: v,
        sends:   total.to_i,
        score:   total > 0 ? (s / total * 100).round(1) : nil,
        successes: s.to_i,
        failures:  f.to_i
      }
    end
  end

  private

  # Thompson Sampling: draw from Beta distribution
  def self.thompson_sample(stat)
    alpha = stat['successes'].to_f + 1.0
    beta  = stat['failures'].to_f  + 1.0
    beta_sample(alpha, beta)
  end

  # Approximate Beta(a,b) sample using Gamma distribution trick
  def self.beta_sample(alpha, beta)
    x = gamma_sample(alpha)
    y = gamma_sample(beta)
    x / (x + y)
  end

  def self.gamma_sample(shape)
    # Marsaglia-Tsang method (simplified for small integers)
    return rand ** (1.0 / shape) if shape < 1
    d = shape - 1.0 / 3.0
    c = 1.0 / Math.sqrt(9 * d)
    loop do
      x = rand_normal
      v = (1 + c * x) ** 3
      next if v <= 0
      u = rand
      return d * v if u < 1 - 0.0331 * (x * x) ** 2
      return d * v if Math.log(u) < 0.5 * x * x + d * (1 - v + Math.log(v))
    end
  end

  def self.rand_normal
    # Box-Muller transform
    u1, u2 = rand, rand
    Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math::PI * u2)
  end

  def self.load_stats(storm_event_id)
    Rails.cache.read(cache_key(storm_event_id)) || fresh_stats
  end

  def self.fresh_stats
    VARIANTS.each_with_object({}) { |v, h| h[v] = { 'successes' => 0, 'failures' => 0 } }
  end

  def self.cache_key(storm_event_id)
    storm_event_id ? "variant_stats_storm_#{storm_event_id}" : 'variant_stats_global'
  end
end

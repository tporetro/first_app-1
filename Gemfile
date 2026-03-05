source 'https://rubygems.org'

# Bundle edge Rails instead: gem 'rails', github: 'rails/rails'
gem 'rails', '4.0.0.beta1'

# --- Storm Lead Pipeline dependencies ---

# Claude API (AI email composition, prospect research)
gem 'anthropic'

# CSV processing (Phase 2 property import)
gem 'smarter_csv'

# HTTP (used by service objects — stdlib Net::HTTP is fine but this is cleaner)
gem 'httparty'

# Background job processing (pipeline phases run as jobs)
gem 'sidekiq'

# Cron-style scheduling for Sidekiq (storm monitor every 15 min, Amy follow-ups daily)
gem 'sidekiq-cron'

# In-memory cache for variant optimizer Thompson Sampling state
# (Redis in production via REDIS_URL, memory store in dev)
gem 'redis'
gem 'redis-store'
gem 'redis-rails'

group :development do
  gem 'sqlite3', '1.3.7'
  gem 'dotenv-rails'  # load .env for ANTHROPIC_API_KEY, CLAY_API_KEY, etc.
end

group :assets do
  gem 'sass-rails',   '4.0.0.beta1'
  gem 'coffee-rails', '4.0.0.beta1'
  gem 'uglifier', '1.0.3'
end

gem 'jquery-rails', '2.2.1'
gem 'turbolinks', '1.0.0'
gem 'jbuilder', '1.0.1'

group :production do
  gem 'pg', '0.12.2'
end
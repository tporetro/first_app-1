source 'https://rubygems.org'

ruby '3.3.6'

gem 'rails', '~> 7.1'

# --- Storm Lead Pipeline dependencies ---

# Claude API (AI email composition, prospect research)
gem 'anthropic'

# CSV processing (Phase 2 property import)
gem 'smarter_csv'

# ZIP file extraction (Phase 2 CAD bulk download unpacking)
gem 'rubyzip'

# HTTP (used by service objects)
gem 'httparty'

# Background job processing (pipeline phases run as jobs)
gem 'sidekiq'

# Cron-style scheduling for Sidekiq (storm monitor every 15 min, Amy follow-ups daily)
gem 'sidekiq-cron'

# In-memory cache for variant optimizer Thompson Sampling state
gem 'redis'

# Asset pipeline
gem 'sprockets-rails'
gem 'sass-rails'
gem 'uglifier'

gem 'jquery-rails'
gem 'turbolinks', '~> 5'
gem 'jbuilder'
gem 'puma', '~> 6.0'

group :development do
  gem 'sqlite3', '~> 1.6'
  gem 'dotenv-rails'
end

group :production do
  gem 'pg'
  gem 'mini_racer'  # V8 JS runtime for uglifier (asset precompilation on Render)
end

group :development, :test do
  gem 'debug'
  gem 'minitest', '~> 5.25'
end

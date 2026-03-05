FirstApp::Application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local       = false
  config.action_controller.perform_caching = true

  # Serve static files (Render serves them directly)
  config.public_file_server.enabled = ENV['RAILS_SERVE_STATIC_FILES'].present?

  # Compress JavaScripts and CSS.
  config.assets.js_compressor  = nil  # Uglifier/MiniRacer incompatible; CDN handles compression
  config.assets.compile = false
  config.assets.digest = true
  config.assets.version = '1.0'

  config.log_level = :info
  config.i18n.fallbacks = true
  config.active_support.report_deprecations = false
  config.log_formatter = ::Logger::Formatter.new
  config.force_ssl = false
end

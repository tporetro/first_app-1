FirstApp::Application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local       = true
  config.action_controller.perform_caching = false
  config.action_mailer.raise_delivery_errors = false
  config.active_support.report_deprecations = true
  config.active_record.migration_error = :page_load
  config.assets.debug = true
end

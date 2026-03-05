class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception

  before_action :require_auth

  private

  # HTTP Basic Auth guards the entire dashboard and CRM.
  # Webhooks skip this — they authenticate via HMAC signature instead.
  # Set DASHBOARD_USERNAME and DASHBOARD_PASSWORD in ENV (production).
  def require_auth
    return if self.class.name.start_with?('Webhooks::')

    authenticate_or_request_with_http_basic('Storm Lead Pipeline') do |user, pass|
      expected_user = ENV.fetch('DASHBOARD_USERNAME', 'admin')
      expected_pass = ENV.fetch('DASHBOARD_PASSWORD') { raise 'DASHBOARD_PASSWORD not set' }
      ActiveSupport::SecurityUtils.secure_compare(user, expected_user) &&
        ActiveSupport::SecurityUtils.secure_compare(pass, expected_pass)
    end
  end
end

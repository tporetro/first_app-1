require 'net/http'
require 'uri'
require 'json'

# Sends mobile push notifications via Pushover API.
# Matches Python send_pushover() helper from the pipeline reference script.
class PushoverService
  API_URL = 'https://api.pushover.net/1/messages.json'.freeze

  def self.notify(title:, message:)
    token = ENV['PUSHOVER_API_TOKEN']
    user  = ENV['PUSHOVER_USER_KEY']

    unless token && user
      Rails.logger.warn "Pushover not configured. Title: #{title} | #{message}"
      return false
    end

    uri = URI.parse(API_URL)
    Net::HTTP.post_form(uri, token: token, user: user, title: title, message: message)
    true
  rescue StandardError => e
    Rails.logger.error "Pushover error: #{e.message}"
    false
  end
end

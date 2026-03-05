# Read-only view of generated Gamma reports per storm/property.
class ReportsController < ApplicationController
  def index
    @storm   = StormEvent.find(params[:storm_id])
    @reports = @storm.properties
      .joins(:gamma_report)
      .includes(:gamma_report, :email_outreaches => [:contact, :email_campaign])
      .order('properties.address')
  end
end

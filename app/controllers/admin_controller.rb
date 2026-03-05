class AdminController < ApplicationController
  def seed_demo
    EmailCampaign.delete_all
    EmailOutreach.delete_all
    GammaReport.delete_all
    Contact.delete_all
    Property.delete_all
    StormEvent.delete_all
    load Rails.root.join('db', 'seeds.rb')
    redirect_to root_path, notice: 'Demo data seeded successfully.'
  end
end

class AdminController < ApplicationController
  def seed_demo
    Rake::Task['demo:seed_dallas'].invoke
    redirect_to root_path, notice: 'Demo data seeded successfully.'
  end
end

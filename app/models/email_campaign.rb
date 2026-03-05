class EmailCampaign < ActiveRecord::Base
  belongs_to :email_outreach

  scope :opened,   -> { where.not(opened_at: nil) }
  scope :clicked,  -> { where.not(clicked_at: nil) }
  scope :replied,  -> { where.not(replied_at: nil) }
  scope :pending,  -> { where(replied_at: nil) }

  def opened?  = opened_at.present?
  def clicked? = clicked_at.present?
  def replied? = replied_at.present?
end

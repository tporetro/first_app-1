class EmailOutreach < ActiveRecord::Base
  belongs_to :property
  belongs_to :contact
  belongs_to :gamma_report, optional: true
  has_one    :email_campaign, dependent: :destroy

  validates :subject, :body, presence: true

  scope :sent,     -> { where(status: 'sent') }
  scope :initial,  -> { where(followup_day: 0) }
  scope :followup, -> { where.not(followup_day: 0) }
end

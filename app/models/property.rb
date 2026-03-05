class Property < ActiveRecord::Base
  belongs_to :storm_event
  has_one    :gamma_report, dependent: :destroy
  has_many   :email_outreaches, dependent: :destroy

  validates :address, :city, :state, :county, presence: true

  scope :identified, -> { where(status: 'identified') }
  scope :emailable,  -> { where.not(status: %w[excluded]) }
end

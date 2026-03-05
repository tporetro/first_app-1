class GammaReport < ActiveRecord::Base
  belongs_to :property
  has_many   :email_outreaches, dependent: :nullify

  validates :report_id, presence: true, uniqueness: true

  scope :completed, -> { where(status: 'completed') }
end

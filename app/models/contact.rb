class Contact < ActiveRecord::Base
  belongs_to :storm_event
  has_many   :email_outreaches, dependent: :destroy

  validates :owner_entity, presence: true

  scope :enriched,       -> { where(status: 'enriched') }
  scope :with_email,     -> { where.not(owner_email: [nil, '']) }
  scope :email_verified, -> { where(email_verified: true) }
end

class Contact < ActiveRecord::Base
  belongs_to :storm_event
  has_many   :email_outreaches, dependent: :destroy

  validates :owner_entity, presence: true
  validates :deal_status, inclusion: {
    in: %w[prospecting in_negotiation won lost do_not_contact]
  }, allow_nil: true

  scope :enriched,          -> { where(status: 'enriched') }
  scope :with_email,        -> { where.not(owner_email: [nil, '']) }
  scope :email_verified,    -> { where(email_verified: true) }
  scope :low_confidence,    -> { where(status: 'low_confidence') }
  scope :active_deals,      -> { where(deal_status: %w[prospecting in_negotiation]) }
  scope :do_not_contact,    -> { where(deal_status: 'do_not_contact') }
  scope :search, ->(q) {
    q = "%#{q.downcase}%"
    where(
      'LOWER(owner_entity) LIKE ? OR LOWER(human_owner_name) LIKE ? OR LOWER(owner_email) LIKE ? OR LOWER(parent_company) LIKE ?',
      q, q, q, q
    )
  }

  DEAL_STATUS_LABELS = {
    'prospecting'    => { label: 'Prospecting',    badge: 'badge-blue'  },
    'in_negotiation' => { label: 'In Negotiation', badge: 'badge-amber' },
    'won'            => { label: 'Won',             badge: 'badge-green' },
    'lost'           => { label: 'Lost',            badge: 'badge-slate' },
    'do_not_contact' => { label: 'Do Not Contact', badge: 'badge-red'   }
  }.freeze
end

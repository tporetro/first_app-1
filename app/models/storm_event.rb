class StormEvent < ActiveRecord::Base
  has_many :properties, dependent: :destroy
  has_many :contacts,   dependent: :destroy

  validates :name,       presence: true
  validates :event_date, presence: true
  validates :hail_size,  presence: true, numericality: { greater_than: 0 }
  validates :counties,   presence: true
  validates :state,      presence: true

  scope :detected,   -> { where(status: 'detected') }
  scope :processing, -> { where(status: 'processing') }
  scope :complete,   -> { where(status: 'complete') }
  scope :error,      -> { where(status: 'error') }
  scope :recent,     -> { order(event_date: :desc) }
end

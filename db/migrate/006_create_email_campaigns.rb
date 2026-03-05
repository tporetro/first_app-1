# Tracks Mailgun delivery events and reply detection (open, click, delivered, replied)
class CreateEmailCampaigns < ActiveRecord::Migration[7.2]
  def change
    create_table :email_campaigns do |t|
      t.references :email_outreach, null: false
      t.string  :mailgun_message_id
      t.string  :owner_name
      t.string  :address
      t.string  :variant              # a|b|c|d for A/B/C/D subject line testing
      t.datetime :delivered_at
      t.datetime :opened_at
      t.datetime :clicked_at
      t.datetime :replied_at
      t.string  :status, default: 'sent'  # sent|delivered|opened|clicked|replied|bounced

      t.timestamps
    end

    add_index :email_campaigns, :email_outreach_id unless index_exists?(:email_campaigns, :email_outreach_id)
    add_index :email_campaigns, :mailgun_message_id unless index_exists?(:email_campaigns, :mailgun_message_id)
    add_index :email_campaigns, :status unless index_exists?(:email_campaigns, :status)
  end
end

class CreateEmailOutreaches < ActiveRecord::Migration
  def change
    create_table :email_outreaches do |t|
      t.references :property,    null: false
      t.references :contact,     null: false
      t.references :gamma_report
      t.string  :subject,        null: false
      t.text    :body,           null: false
      t.string  :sent_to_email
      t.string  :gmail_message_id
      t.string  :status, default: 'draft'  # draft|sent|failed|no_email
      t.datetime :sent_at
      t.integer :followup_day,   default: 0  # 0=initial, 3, 7, 14, 21
      t.text    :error_message

      t.timestamps
    end

    add_index :email_outreaches, :property_id
    add_index :email_outreaches, :contact_id
    add_index :email_outreaches, :status
    add_index :email_outreaches, :sent_at
  end
end

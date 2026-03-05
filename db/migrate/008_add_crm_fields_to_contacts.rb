class AddCrmFieldsToContacts < ActiveRecord::Migration
  def change
    add_column :contacts, :deal_status, :string, default: 'prospecting'
    # prospecting | in_negotiation | won | lost | do_not_contact
    add_column :contacts, :notes, :text
    add_column :contacts, :last_activity_at, :datetime

    add_index :contacts, :deal_status
  end
end

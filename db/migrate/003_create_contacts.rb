class CreateContacts < ActiveRecord::Migration[7.2]
  def change
    create_table :contacts do |t|
      t.references :storm_event, null: false
      t.string  :owner_entity,    null: false
      t.string  :human_owner_name
      t.string  :owner_title
      t.string  :owner_email
      t.string  :owner_phone
      t.string  :owner_linkedin
      t.string  :parent_company
      t.string  :org_domain
      t.string  :enrichment_source  # apollo|secretary_of_state|website|linkedin|manual
      t.boolean :email_verified,   default: false
      t.string  :status, default: 'pending'  # pending|enriched|failed

      t.timestamps
    end

    add_index :contacts, :storm_event_id
    add_index :contacts, :owner_entity
    add_index :contacts, :owner_email
  end
end

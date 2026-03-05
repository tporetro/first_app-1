class CreateProperties < ActiveRecord::Migration[7.2]
  def change
    create_table :properties do |t|
      t.references :storm_event, null: false
      t.string  :property_id
      t.string  :address,       null: false
      t.string  :city,          null: false
      t.string  :state,         null: false
      t.string  :county,        null: false
      t.string  :property_type
      t.integer :sq_ft
      t.string  :owner_entity
      t.string  :roof_system
      t.string  :status, default: 'identified'  # identified|enriched|reported|emailed|excluded

      t.timestamps
    end

    add_index :properties, :storm_event_id
    add_index :properties, :status
    add_index :properties, :owner_entity
  end
end

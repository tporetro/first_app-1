class CreateStormEvents < ActiveRecord::Migration
  def change
    create_table :storm_events do |t|
      t.string  :name,          null: false
      t.date    :event_date,    null: false
      t.decimal :hail_size,     precision: 4, scale: 2, null: false  # inches
      t.string  :counties,      null: false   # comma-separated county list
      t.string  :state,         null: false
      t.string  :metro_area
      t.text    :boundary_definition
      t.string  :swath_map_path               # path to saved map image
      t.string  :status, default: 'detected'  # detected|processing|complete|error
      t.text    :notes

      t.timestamps
    end

    add_index :storm_events, :event_date
    add_index :storm_events, :status
  end
end

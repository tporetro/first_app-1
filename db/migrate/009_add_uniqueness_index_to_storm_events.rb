class AddUniquenessIndexToStormEvents < ActiveRecord::Migration
  def change
    # Prevents duplicate storm events from repeated NOAA monitor cycles.
    # Composite key: event_date + state + metro_area.
    add_index :storm_events, [:event_date, :state, :metro_area],
              unique: true, name: 'index_storm_events_unique_per_day'
  end
end

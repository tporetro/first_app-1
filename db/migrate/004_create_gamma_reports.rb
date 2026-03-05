class CreateGammaReports < ActiveRecord::Migration[7.2]
  def change
    create_table :gamma_reports do |t|
      t.references :property, null: false
      t.string  :report_id,     null: false
      t.string  :generation_id              # Gamma API generation ID for polling
      t.string  :gamma_url
      t.string  :markdown_path              # local path to source markdown
      t.integer :credits_used
      t.string  :status, default: 'pending' # pending|generating|completed|failed
      t.text    :error_message

      t.timestamps
    end

    add_index :gamma_reports, :property_id
    add_index :gamma_reports, :generation_id
    add_index :gamma_reports, :status
  end
end

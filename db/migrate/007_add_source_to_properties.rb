class AddSourceToProperties < ActiveRecord::Migration
  def change
    add_column :properties, :source, :string  # cad_auto|manual|import
    add_index  :properties, :source
  end
end

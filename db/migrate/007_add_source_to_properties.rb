class AddSourceToProperties < ActiveRecord::Migration[7.2]
  def change
    add_column :properties, :source, :string  # cad_auto|manual|import
    add_index  :properties, :source unless index_exists?(:properties, :source)
  end
end

class AddWallosIntegration < ActiveRecord::Migration[7.2]
  def change
    create_table :wallos_connections, id: :uuid do |t|
      t.references :family, null: false, foreign_key: true, type: :uuid, index: { unique: true }
      t.references :account, null: false, foreign_key: { on_delete: :cascade }, type: :uuid
      t.string :base_url, null: false
      t.text :api_key, null: false
      t.datetime :last_synced_at
      t.timestamps
    end

    add_column :recurring_transactions, :source, :string
    add_column :recurring_transactions, :source_id, :string
    add_column :recurring_transactions, :source_metadata, :jsonb, null: false, default: {}
    add_index :recurring_transactions, [ :family_id, :source, :source_id ],
      unique: true,
      where: "source IS NOT NULL AND source_id IS NOT NULL",
      name: "idx_recurring_txns_on_external_source"
  end
end

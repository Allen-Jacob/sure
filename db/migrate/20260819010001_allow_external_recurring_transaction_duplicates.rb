class AllowExternalRecurringTransactionDuplicates < ActiveRecord::Migration[7.2]
  def up
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_name"
    add_index :recurring_transactions,
      [ :family_id, :account_id, :name, :amount, :currency ],
      unique: true,
      where: "name IS NOT NULL AND merchant_id IS NULL AND destination_account_id IS NULL AND source IS NULL",
      name: "idx_recurring_txns_acct_name"
  end

  def down
    remove_index :recurring_transactions, name: "idx_recurring_txns_acct_name"
    add_index :recurring_transactions,
      [ :family_id, :account_id, :name, :amount, :currency ],
      unique: true,
      where: "name IS NOT NULL AND merchant_id IS NULL AND destination_account_id IS NULL",
      name: "idx_recurring_txns_acct_name"
  end
end

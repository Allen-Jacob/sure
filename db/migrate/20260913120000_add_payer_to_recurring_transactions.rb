class AddPayerToRecurringTransactions < ActiveRecord::Migration[8.1]
  def change
    add_reference :recurring_transactions, :payer, type: :uuid,
                  foreign_key: { to_table: :users, on_delete: :nullify }
  end
end

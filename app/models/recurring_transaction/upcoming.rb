class RecurringTransaction::Upcoming
  def initialize(user:, account: nil, from: Date.current, to: Date.current + 90)
    @user, @account, @from, @to = user, account, from, to
  end

  def occurrences
    series = @user.family.recurring_transactions.accessible_by(@user).active
    if @account
      series = series.where(account_id: @account.id).or(series.where(destination_account_id: @account.id))
    end

    @user.family.recurring_occurrences.open_status
      .where(recurring_transaction_id: series.select(:id))
      .where("GREATEST(due_on, COALESCE(snoozed_until, due_on)) BETWEEN ? AND ?", @from, @to)
      .includes(recurring_transaction: [ :merchant, :account, :destination_account ])
      .order(Arel.sql("GREATEST(due_on, COALESCE(snoozed_until, due_on)) ASC"), :id)
  end
end

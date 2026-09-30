module UpcomingHelper
  def upcoming_amount(occurrence, account: nil)
    series = occurrence.recurring_transaction
    income = series.amount.negative? || (account && series.destination_account_id == account.id)
    amount = occurrence.resolved_expected_amount_money
    income ? amount : -amount
  end
end

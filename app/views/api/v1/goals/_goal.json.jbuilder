# frozen_string_literal: true

money_to_minor_units = lambda do |money|
  (money.amount * money.currency.minor_unit_conversion).round(0).to_i if money
end

json.id goal.id
json.name goal.name
json.currency goal.currency
json.target_date goal.target_date
json.state goal.state
json.status goal.display_status.to_s
json.progress_percent goal.progress_percent
json.color goal.color
json.icon goal.icon

json.target_amount goal.target_amount_money.format
json.target_amount_cents money_to_minor_units.call(goal.target_amount_money)
json.current_amount goal.current_balance_money.format
json.current_amount_cents money_to_minor_units.call(goal.current_balance_money)
json.remaining_amount goal.remaining_amount_money.format
json.remaining_amount_cents money_to_minor_units.call(goal.remaining_amount_money)

json.created_at goal.created_at.iso8601
json.updated_at goal.updated_at.iso8601

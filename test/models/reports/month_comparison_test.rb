require "test_helper"

class Reports::MonthComparisonTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @today = Date.new(2026, 8, 9)
    @user = users(:empty)
    @family = @user.family
    @family.update!(currency: "USD")
    @account = @family.accounts.create!(
      owner: @user,
      name: "Comparison checking",
      balance: 0,
      currency: "USD",
      accountable: Depository.new
    )
    @salary = @family.categories.create!(name: "Comparison salary", color: "#10B981")
    @groceries = @family.categories.create!(name: "Comparison groceries", color: "#F59E0B")

    create_transaction(account: @account, name: "Salary 2026", amount: -3000, date: Date.new(2026, 8, 5), category: @salary)
    create_transaction(account: @account, name: "Salary 2025", amount: -2000, date: Date.new(2025, 8, 5), category: @salary)
    create_transaction(account: @account, name: "Groceries 2026", amount: 900, date: Date.new(2026, 8, 6), category: @groceries)
    create_transaction(account: @account, name: "Groceries 2025", amount: 600, date: Date.new(2025, 8, 6), category: @groceries)
  end

  test "compares income expenses savings and categories" do
    comparison = Reports::MonthComparison.new(
      income_statement: IncomeStatement.new(@family, user: @user),
      primary_month: Date.new(2026, 8, 1),
      comparison_month: Date.new(2025, 8, 1),
      currency: "USD",
      today: @today
    )

    assert_equal 3000.to_d, comparison.primary[:income].amount
    assert_equal 900.to_d, comparison.primary[:expenses].amount
    assert_equal 2100.to_d, comparison.primary[:net_savings].amount
    assert_equal 70.to_d, comparison.primary[:savings_rate]

    income_metric = comparison.metrics.find { |metric| metric[:key] == :income }
    assert_equal 1000.to_d, income_metric[:delta].amount
    assert_equal 50.to_d, income_metric[:percent_change]

    expense_row = comparison.expense_categories.find { |row| row[:category] == @groceries }
    assert_equal 300.to_d, expense_row[:delta].amount
    assert_equal 50.to_d, expense_row[:percent_change]
  end

  test "aligns a current month and historical month through the same day" do
    comparison = Reports::MonthComparison.new(
      income_statement: IncomeStatement.new(@family, user: @user),
      primary_month: Date.new(2026, 8, 1),
      comparison_month: Date.new(2025, 8, 1),
      currency: "USD",
      today: @today
    )

    assert comparison.partial_period?
    assert_equal Date.new(2026, 8, 9), comparison.primary_period.end_date
    assert_equal Date.new(2025, 8, 9), comparison.comparison_period.end_date
  end
end

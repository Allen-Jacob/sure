require "test_helper"

class Dashboard::FinancialSnapshotTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @today = Date.new(2026, 8, 6)
    @user = users(:empty)
    @family = @user.family
    @family.update!(currency: "USD")

    @checking = @family.accounts.create!(
      owner: @user,
      name: "Everyday Checking",
      balance: 5000,
      currency: "USD",
      accountable: Depository.new
    )
    @card = @family.accounts.create!(
      owner: @user,
      name: "Main Card",
      balance: 1000,
      currency: "USD",
      accountable: CreditCard.new
    )
    @family.accounts.create!(
      owner: @user,
      name: "Canadian Savings",
      balance: 9999,
      currency: "CAD",
      accountable: Depository.new
    )

    salary = @family.categories.create!(name: "Salary", color: "#10B981")
    fuel = @family.categories.create!(name: "Fuel", color: "#F59E0B")
    create_transaction(account: @checking, name: "Acme Payroll", amount: -2000, date: @today - 21, category: salary)
    create_transaction(account: @checking, name: "Acme Payroll", amount: -2000, date: @today - 7, category: salary)
    create_transaction(account: @checking, name: "Previous fuel", amount: 100, date: @today - 8, category: fuel)
    create_transaction(account: @checking, name: "Fuel stop", amount: 200, date: @today - 5, category: fuel)
    create_transaction(account: @checking, name: "Needs a category", amount: 50, date: @today - 2)

    @family.recurring_transactions.create!(
      account: @checking,
      name: "Internet",
      amount: 100,
      currency: "USD",
      expected_day_of_month: (@today + 3).day,
      last_occurrence_date: @today - 1.month,
      next_expected_date: @today + 3,
      status: "active",
      occurrence_count: 3
    )

    goal = @family.goals.build(
      name: "New car",
      target_amount: 2000,
      target_date: @today + 6.months,
      currency: "USD"
    )
    goal.goal_accounts.build(account: @checking, allocated_amount: 500)
    goal.save!
  end

  test "builds the payday dashboard from accessible financial data" do
    snapshot = Dashboard::FinancialSnapshot.new(
      family: @family,
      user: @user,
      accounts: @user.accessible_accounts.visible,
      today: @today
    ).to_h

    assert_equal @today + 7, snapshot.dig(:paycheck, :next_date)
    assert_equal 2000.to_d, snapshot.dig(:paycheck, :amount).amount
    assert snapshot.dig(:paycheck, :estimated)

    assert_equal 250.to_d, snapshot.dig(:spending, :total).amount
    assert_equal 100.to_d, snapshot.dig(:spending, :previous_total).amount
    assert_equal 150, snapshot.dig(:spending, :change_percent)

    assert_equal 3400.to_d, snapshot.dig(:available, :amount).amount
    assert_equal 5000.to_d, snapshot.dig(:available, :cash).amount
    assert_equal 1000.to_d, snapshot.dig(:available, :card_debt).amount
    assert_equal 500.to_d, snapshot.dig(:available, :reserved).amount
    assert_equal 100.to_d, snapshot.dig(:available, :planned).amount
    assert_equal 1, snapshot.fetch(:ignored_account_count)
    assert_equal 7, snapshot.dig(:budget, :days_remaining)
    assert_equal 3400.to_d / 7, snapshot.dig(:budget, :daily).amount

    allocation = snapshot.dig(:allocation, :items).index_by { |item| item.fetch(:key) }
    assert_equal 100.to_d, allocation.dig(:fixed, :amount).amount
    assert_equal 1000.to_d, allocation.dig(:card, :amount).amount
    assert_equal 200.to_d, allocation.dig(:savings, :amount).amount
    assert_equal 700.to_d, allocation.dig(:free, :amount).amount
    assert_equal 2000.to_d, allocation.values.sum { |item| item.fetch(:amount).amount }

    assert_equal "New car", snapshot.dig(:goals, 0).name
    assert_equal 1, snapshot.fetch(:purchases).size
    assert_equal 1, snapshot.dig(:review, :uncategorized)
    assert_equal [ "Fuel", Category.uncategorized.display_name ], snapshot.fetch(:categories).map { |category| category[:name] }
  end

  test "does not treat a credit card overpayment as negative debt" do
    @card.update!(balance: -100)

    snapshot = Dashboard::FinancialSnapshot.new(
      family: @family,
      user: @user,
      accounts: @user.accessible_accounts.visible,
      today: @today
    ).to_h

    assert_equal 0.to_d, snapshot.dig(:available, :card_debt).amount
    assert_equal 0.to_d, snapshot.dig(:allocation, :items, 0, :amount).amount
  end

  test "uses configured accounts and a category whose name is instance-specific" do
    payroll_category = @family.categories.create!(name: "Versement usine 42", color: "#2563EB")
    expense_category = @family.categories.create!(name: "Dépense locale", color: "#9333EA")
    selected_cash = @family.accounts.create!(
      owner: @user,
      name: "Compte quotidien personnalisé",
      balance: 2000,
      currency: "USD",
      accountable: Depository.new
    )
    selected_card = @family.accounts.create!(
      owner: @user,
      name: "Carte personnalisée",
      balance: 300,
      currency: "USD",
      accountable: CreditCard.new
    )
    create_transaction(account: selected_cash, name: "Virement 9831", amount: -1500, date: @today - 20, category: payroll_category)
    create_transaction(account: selected_cash, name: "Virement 9831", amount: -1500, date: @today - 6, category: payroll_category)
    create_transaction(account: selected_cash, name: "Achat local", amount: 40, date: @today - 3, category: expense_category)
    @user.update_dashboard_cash_plan_settings({
      "depository_account_ids" => [ selected_cash.id.to_s ],
      "credit_card_account_ids" => [ selected_card.id.to_s ],
      "payroll_category_ids" => [ payroll_category.id.to_s ],
      "primary_credit_card_id" => selected_card.id.to_s,
      "pay_cycle_days" => 14
    })

    snapshot = Dashboard::FinancialSnapshot.new(
      family: @family,
      user: @user,
      accounts: @user.accessible_accounts.visible,
      today: @today
    ).to_h

    assert_equal "Virement 9831", snapshot.dig(:paycheck, :name)
    assert_equal 1500.to_d, snapshot.dig(:paycheck, :amount).amount
    assert_equal @today + 8, snapshot.dig(:paycheck, :next_date)
    assert_equal 40.to_d, snapshot.dig(:spending, :total).amount
    assert_equal 1700.to_d, snapshot.dig(:available, :amount).amount
    assert_equal selected_card, snapshot.dig(:credit_card, :account)
    assert_equal [ "Dépense locale" ], snapshot.fetch(:categories).map { |category| category[:name] }
  end

  test "falls back to compatible accounts when stored ids do not exist on this instance" do
    @user.update_dashboard_cash_plan_settings({
      "depository_account_ids" => [ "old-cash-account" ],
      "credit_card_account_ids" => [ "old-card-account" ],
      "payroll_category_ids" => [ "old-payroll-category" ],
      "primary_credit_card_id" => "old-primary-card",
      "pay_cycle_days" => 14
    })

    snapshot = Dashboard::FinancialSnapshot.new(
      family: @family,
      user: @user,
      accounts: @user.accessible_accounts.visible,
      today: @today
    ).to_h

    assert_equal 5000.to_d, snapshot.dig(:available, :cash).amount
    assert_equal 1000.to_d, snapshot.dig(:available, :card_debt).amount
    assert_equal 2000.to_d, snapshot.dig(:paycheck, :amount).amount
    assert_equal @card, snapshot.dig(:credit_card, :account)
  end

  test "manual pay schedule overrides inferred payroll data" do
    @user.update_dashboard_cash_plan_settings({
      "next_pay_date" => (@today + 4).iso8601,
      "expected_pay_amount" => "3100.50",
      "pay_cycle_days" => 14
    })

    snapshot = Dashboard::FinancialSnapshot.new(
      family: @family,
      user: @user,
      accounts: @user.accessible_accounts.visible,
      today: @today
    ).to_h

    assert_equal I18n.t("pages.dashboard.cash_plan.paycheck_configured"), snapshot.dig(:paycheck, :name)
    assert_equal 3100.50.to_d, snapshot.dig(:paycheck, :amount).amount
    assert_equal @today + 4, snapshot.dig(:paycheck, :next_date)
    assert_equal @today - 10, snapshot.dig(:paycheck, :last_date)
    assert snapshot.dig(:paycheck, :configured)
    assert_not snapshot.dig(:paycheck, :estimated)
  end

  test "old manual pay dates advance without iterating one pay cycle at a time" do
    @user.update_dashboard_cash_plan_settings({
      "next_pay_date" => (@today - 29).iso8601,
      "expected_pay_amount" => "2500",
      "pay_cycle_days" => 14
    })

    snapshot = Dashboard::FinancialSnapshot.new(
      family: @family,
      user: @user,
      accounts: @user.accessible_accounts.visible,
      today: @today
    ).to_h

    assert_equal @today + 13, snapshot.dig(:paycheck, :next_date)
    assert_equal @today - 1, snapshot.dig(:paycheck, :last_date)
  end
end

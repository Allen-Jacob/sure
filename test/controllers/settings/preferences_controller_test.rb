require "test_helper"

class Settings::PreferencesControllerTest < ActionDispatch::IntegrationTest
  setup do
    ensure_tailwind_build
    sign_in users(:family_admin)
  end

  test "get" do
    get settings_preferences_url

    assert_response :success
    assert_includes response.body, "Dashboard cash plan"
    assert_select "form input[name='dashboard_cash_plan[depository_account_ids][]']", minimum: 1
    assert_select "form input[name='dashboard_cash_plan[payroll_category_ids][]']", minimum: 1
    assert_select "form input[name^='dashboard_cash_plan[paycheck_allocations]']", minimum: 1
    assert_select "form input[name='dashboard_cash_plan[work_calendar_url]']", count: 1
    assert_select "form input[name='dashboard_cash_plan[hourly_pay_rate]']", count: 1
    assert_select "form input[name='dashboard_cash_plan[pay_period_anchor_date]']", count: 1
    assert_select "form input[name='dashboard_cash_plan[payday_offset_days]']", count: 1
  end

  test "group moniker uses group currencies copy and hides legacy currency field" do
    users(:family_admin).family.update!(moniker: "Group")

    get settings_preferences_url

    assert_response :success
    assert_includes response.body, "Group Currencies"
    assert_includes response.body, "your group"
    assert_select "select[name='user[family_attributes][currency]']", count: 0
  end

  test "renders preview features toggle for non-admin users too" do
    sign_in users(:family_member)
    get settings_preferences_url

    assert_response :success
    assert_includes response.body, "Enable preview features"
  end

  test "update toggles preview_features_enabled on" do
    user = users(:family_admin)
    assert_not user.preview_features_enabled?

    patch settings_preferences_url, params: { user: { preview_features_enabled: "1" } }

    assert_redirected_to settings_preferences_url
    assert user.reload.preview_features_enabled?
  end

  test "update toggles preview_features_enabled off" do
    user = users(:family_admin)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))
    assert user.preview_features_enabled?

    patch settings_preferences_url, params: { user: { preview_features_enabled: "0" } }

    assert_redirected_to settings_preferences_url
    assert_not user.reload.preview_features_enabled?
  end

  test "household budget toggle and sharing card only render once personal_budgets is on" do
    user = users(:family_admin)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))

    get settings_preferences_url
    assert_response :success
    assert_not_includes response.body, I18n.t("settings.preferences.show.household_budget_enabled")
    assert_not_includes response.body, I18n.t("settings.preferences.show.budget_sharing_title")

    user.family.update!(personal_budgets: true)

    get settings_preferences_url
    assert_response :success
    assert_includes response.body, I18n.t("settings.preferences.show.household_budget_enabled")
    assert_includes response.body, I18n.t("settings.preferences.show.budget_sharing_title")
  end

  test "hides the sharing card when personal_budgets is on but preview features are off" do
    user = users(:family_admin)
    user.family.update!(personal_budgets: true)
    assert_not user.preview_features_enabled?

    get settings_preferences_url

    assert_response :success
    assert_not_includes response.body, I18n.t("settings.preferences.show.household_budget_enabled")
    assert_not_includes response.body, I18n.t("settings.preferences.show.budget_sharing_title")
  end

  test "update saves portable cash plan settings without changing other preferences" do
    user = users(:family_admin)
    user.update!(preferences: { "preview_features_enabled" => true })
    accounts = user.accessible_accounts.visible.where(currency: user.family.primary_currency_code)
    depository = accounts.find_by!(accountable_type: "Depository")
    credit_card = accounts.find_by!(accountable_type: "CreditCard")
    category = user.family.categories.first!

    patch settings_preferences_url, params: {
      dashboard_cash_plan: {
        depository_account_ids: [ depository.id ],
        credit_card_account_ids: [ credit_card.id ],
        payroll_category_ids: [ category.id ],
        primary_credit_card_id: credit_card.id,
        pay_cycle_days: 15,
        next_pay_date: "2026-08-15",
        expected_pay_amount: "2450.75"
      }
    }

    assert_redirected_to settings_preferences_url
    settings = user.reload.dashboard_cash_plan_settings
    assert_equal [ depository.id.to_s ], settings["depository_account_ids"]
    assert_equal [ credit_card.id.to_s ], settings["credit_card_account_ids"]
    assert_equal [ category.id.to_s ], settings["payroll_category_ids"]
    assert_equal credit_card.id.to_s, settings["primary_credit_card_id"]
    assert_equal 15, settings["pay_cycle_days"]
    assert_equal "2026-08-15", settings["next_pay_date"]
    assert_equal "2450.75", settings["expected_pay_amount"]
    assert_equal({ depository.id.to_s => "100.0" }, settings["paycheck_allocations"])
    assert user.preview_features_enabled?
  end

  test "update saves a paycheck split between selected cash accounts" do
    user = users(:family_admin)
    accounts = user.accessible_accounts.visible.where(currency: user.family.primary_currency_code)
    checking = accounts.find_by!(accountable_type: "Depository")
    savings = user.family.accounts.create!(
      owner: user,
      name: "Savings for allocation",
      balance: 0,
      currency: user.family.primary_currency_code,
      accountable: Depository.new
    )

    patch settings_preferences_url, params: {
      dashboard_cash_plan: {
        depository_account_ids: [ checking.id, savings.id ],
        pay_cycle_days: 14,
        paycheck_allocations: {
          checking.id => "30",
          savings.id => "70"
        }
      }
    }

    assert_redirected_to settings_preferences_url
    assert_equal(
      { checking.id.to_s => "30.0", savings.id.to_s => "70.0" },
      user.reload.dashboard_cash_plan_settings["paycheck_allocations"]
    )
  end

  test "update saves an Agendrix calendar pay schedule" do
    user = users(:family_admin)
    calendar_url = "https://app.agendrix.com/api/calendar/11111111-2222-3333-4444-555555555555.ics"

    patch settings_preferences_url, params: {
      dashboard_cash_plan: {
        work_calendar_url: calendar_url,
        hourly_pay_rate: "22,50",
        pay_period_anchor_date: "2026-08-02",
        payday_offset_days: "5",
        pay_cycle_days: 14
      }
    }

    assert_redirected_to settings_preferences_url
    settings = user.reload.dashboard_cash_plan_settings
    assert_equal calendar_url, settings["work_calendar_url"]
    assert_equal "22.5", settings["hourly_pay_rate"]
    assert_equal "2026-08-02", settings["pay_period_anchor_date"]
    assert_equal 5, settings["payday_offset_days"]
    assert_equal 14, settings["pay_cycle_days"]
  end

  test "update rejects an unsafe work calendar URL" do
    user = users(:family_admin)
    original_preferences = user.preferences.deep_dup

    patch settings_preferences_url, params: {
      dashboard_cash_plan: {
        work_calendar_url: "http://localhost/private.ics",
        hourly_pay_rate: "22.50",
        pay_period_anchor_date: "2026-08-02",
        payday_offset_days: "5",
        pay_cycle_days: 14
      }
    }

    assert_redirected_to settings_preferences_url
    assert_equal "Enter a valid Agendrix calendar, hourly amount, pay-period start, and payday delay—or leave all four fields empty.", flash[:alert]
    assert_equal original_preferences, user.reload.preferences
  end

  test "update rejects paycheck allocations that do not total 100 percent" do
    user = users(:family_admin)
    original_preferences = user.preferences.deep_dup
    depository = user.accessible_accounts.visible.find_by!(accountable_type: "Depository")

    patch settings_preferences_url, params: {
      dashboard_cash_plan: {
        depository_account_ids: [ depository.id ],
        pay_cycle_days: 14,
        paycheck_allocations: { depository.id => "80" }
      }
    }

    assert_redirected_to settings_preferences_url
    assert_equal "Paycheck allocations must be between 0% and 100% and total exactly 100%.", flash[:alert]
    assert_equal original_preferences, user.reload.preferences
  end

  test "update ignores account and category ids from another family" do
    user = users(:family_admin)
    foreign_family = users(:empty).family
    foreign_account = foreign_family.accounts.create!(
      owner: users(:empty),
      name: "Foreign checking",
      balance: 100,
      currency: user.family.primary_currency_code,
      accountable: Depository.new
    )
    foreign_category = foreign_family.categories.create!(name: "Foreign payroll", color: "#10B981")
    assert_not_equal user.family_id, foreign_account.family_id
    assert_not_equal user.family_id, foreign_category.family_id

    patch settings_preferences_url, params: {
      dashboard_cash_plan: {
        depository_account_ids: [ foreign_account.id ],
        payroll_category_ids: [ foreign_category.id ],
        pay_cycle_days: 14
      }
    }

    assert_redirected_to settings_preferences_url
    settings = user.reload.dashboard_cash_plan_settings
    assert_nil settings["depository_account_ids"]
    assert_nil settings["payroll_category_ids"]
    assert_equal 14, settings["pay_cycle_days"]
  end

  test "update rejects an incomplete manual pay schedule" do
    user = users(:family_admin)
    original_preferences = user.preferences.deep_dup

    patch settings_preferences_url, params: {
      dashboard_cash_plan: {
        pay_cycle_days: 14,
        expected_pay_amount: "2000"
      }
    }

    assert_redirected_to settings_preferences_url
    assert_equal "Enter a valid paycheck date and amount, or leave both fields empty.", flash[:alert]
    assert_equal original_preferences, user.reload.preferences
  end
end

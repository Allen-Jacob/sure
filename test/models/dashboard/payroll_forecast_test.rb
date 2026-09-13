require "test_helper"

class Dashboard::PayrollForecastTest < ActiveSupport::TestCase
  CALENDAR_URL = "https://app.agendrix.com/api/calendar/11111111-2222-3333-4444-555555555555.ics"

  setup do
    @user = users(:family_admin)
    @user.update_dashboard_cash_plan_settings({
      "work_calendar_url" => CALENDAR_URL,
      "hourly_pay_rate" => "22.50",
      "pay_period_anchor_date" => "2026-08-02",
      "payday_offset_days" => 5,
      "pay_cycle_days" => 14
    })
  end

  test "builds consecutive Agendrix paychecks for the dashboard and income plan" do
    calendar = mock
    Dashboard::PayrollCalendar.expects(:new).with(url: CALENDAR_URL).returns(calendar)
    calendar.expects(:hours_between).with(Date.new(2026, 8, 2), Date.new(2026, 8, 15)).returns(10.to_d)
    calendar.expects(:hours_between).with(Date.new(2026, 8, 16), Date.new(2026, 8, 29)).returns(20.to_d)

    forecast = Dashboard::PayrollForecast.new(user: @user, currency: "CAD", today: Date.new(2026, 8, 10))
    occurrences = forecast.planner_occurrences(limit: 2)

    assert_equal [ Date.new(2026, 8, 20), Date.new(2026, 9, 3) ], occurrences.map(&:due_on)
    assert_equal [ 225.to_d, 450.to_d ], occurrences.map { |item| item.resolved_expected_amount_money.amount }
    assert occurrences.all? { |item| item.recurring_transaction_id == "agendrix" }
  end

  test "invalid or incomplete settings produce no forecast" do
    @user.update_dashboard_cash_plan_settings({ "hourly_pay_rate" => "22.50" })

    assert_empty Dashboard::PayrollForecast.new(user: @user, currency: "CAD").forecasts
  end

  test "zero-hour periods do not become income-plan paydays" do
    calendar = mock
    Dashboard::PayrollCalendar.expects(:new).with(url: CALENDAR_URL).returns(calendar)
    calendar.stubs(:hours_between).returns(0.to_d)

    forecast = Dashboard::PayrollForecast.new(user: @user, currency: "CAD", today: Date.new(2026, 8, 10))

    assert_empty forecast.planner_occurrences(limit: 2)
  end
end

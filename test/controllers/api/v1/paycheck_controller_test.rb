# frozen_string_literal: true

require "test_helper"

class Api::V1::PaycheckControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:empty)
    @family = @user.family
    @family.update!(currency: "CAD")
    @user.api_keys.active.destroy_all

    @api_key = ApiKey.create!(
      user: @user,
      name: "Mobile paycheck key",
      scopes: [ "read" ],
      display_key: "test_ro_#{SecureRandom.hex(8)}",
      source: "mobile"
    )

    Redis.new.del("api_rate_limit:#{@api_key.id}")
  end

  test "requires authentication" do
    get "/api/v1/paycheck"

    assert_response :unauthorized
  end

  test "returns the Agendrix paycheck without exposing calendar settings" do
    today = Date.current
    calendar_url = "https://app.agendrix.com/api/calendar/11111111-2222-3333-4444-555555555555.ics"
    calendar = mock
    Dashboard::PayrollCalendar.expects(:new).with(url: calendar_url).returns(calendar)
    calendar.expects(:hours_between).returns(17.5.to_d)
    @user.update_dashboard_cash_plan_settings({
      "work_calendar_url" => calendar_url,
      "hourly_pay_rate" => "22.50",
      "pay_period_anchor_date" => (today - 7).iso8601,
      "payday_offset_days" => 5,
      "pay_cycle_days" => 14
    })

    get "/api/v1/paycheck", headers: api_headers

    assert_response :success
    response_body = JSON.parse(response.body)
    paycheck = response_body.fetch("paycheck")
    assert_equal "CAD", response_body.fetch("currency")
    assert_equal "agendrix", paycheck.fetch("source")
    assert_equal "393.75", paycheck.dig("amount", "amount")
    assert_equal 17.5, paycheck.fetch("scheduled_hours")
    assert paycheck.fetch("estimated")
    assert_not_includes response.body, calendar_url
    assert_not response_body.key?("work_calendar_url")
  end

  private

    def api_headers
      { "X-Api-Key" => @api_key.display_key }
    end
end

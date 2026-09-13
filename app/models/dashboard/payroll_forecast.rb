module Dashboard
  # Turns the private Agendrix calendar configuration into upcoming income
  # events. Both the dashboard and Bills income plan consume these forecasts,
  # so dates and amounts cannot drift between the two surfaces.
  class PayrollForecast
    MAX_FORECASTS = 7
    PAYROLL_KEYWORDS = %w[
      salary payroll paycheck wages wage employer
      salaire paie paye employeur rémunération remuneration
    ].freeze

    Forecast = Data.define(
      :name, :amount, :next_date, :last_date, :days_remaining,
      :scheduled_hours, :pay_period_start, :pay_period_end
    )

    PlannerSource = Data.define(:display_name)
    PlannerOccurrence = Data.define(
      :recurring_transaction_id, :due_on, :resolved_expected_amount_money,
      :recurring_transaction
    )

    def initialize(user:, currency:, today: Date.current)
      @user = user
      @currency = currency
      @today = today
      @settings = user.dashboard_cash_plan_settings
    end

    def next
      forecasts(limit: 1).first
    end

    def forecasts(limit: MAX_FORECASTS)
      schedule = parsed_schedule
      return [] unless schedule

      calendar = Dashboard::PayrollCalendar.new(url: schedule.fetch(:url))
      count = limit.to_i.clamp(1, MAX_FORECASTS)

      Array.new(count) do |index|
        period_start = schedule.fetch(:period_start) + index * schedule.fetch(:cycle_days)
        period_end = period_start + schedule.fetch(:cycle_days) - 1
        next_date = period_end + schedule.fetch(:payday_offset)
        hours = calendar.hours_between(period_start, period_end)

        Forecast.new(
          name: I18n.t("pages.dashboard.cash_plan.paycheck_agendrix"),
          amount: Money.new(schedule.fetch(:hourly_rate) * hours, @currency),
          next_date: next_date,
          last_date: next_date - schedule.fetch(:cycle_days),
          days_remaining: (next_date - @today).to_i,
          scheduled_hours: hours,
          pay_period_start: period_start,
          pay_period_end: period_end
        )
      end
    rescue Dashboard::PayrollCalendar::Error
      []
    end

    def planner_occurrences(limit: MAX_FORECASTS)
      source = PlannerSource.new(display_name: I18n.t("pages.dashboard.cash_plan.paycheck_agendrix"))

      forecasts(limit: limit).filter_map do |forecast|
        next unless forecast.amount.positive?

        PlannerOccurrence.new(
          recurring_transaction_id: "agendrix",
          due_on: forecast.next_date,
          resolved_expected_amount_money: forecast.amount,
          recurring_transaction: source
        )
      end
    end

    private
      def parsed_schedule
        cycle_days = @settings.fetch("pay_cycle_days", 14).to_i
        cycle_days = 14 unless cycle_days.between?(7, 31)
        url = @settings.fetch("work_calendar_url").to_s
        hourly_rate = BigDecimal(@settings.fetch("hourly_pay_rate").to_s)
        anchor_date = Date.iso8601(@settings.fetch("pay_period_anchor_date").to_s)
        payday_offset = Integer(@settings.fetch("payday_offset_days").to_s, 10)
        return unless Dashboard::PayrollCalendar.valid_url?(url)
        return unless hourly_rate.finite? && hourly_rate.positive? && payday_offset.between?(0, 31)

        first_payday = anchor_date + cycle_days - 1 + payday_offset
        elapsed_cycles = [ ((@today - first_payday).to_i.fdiv(cycle_days)).ceil, 0 ].max

        {
          url: url,
          hourly_rate: hourly_rate,
          cycle_days: cycle_days,
          payday_offset: payday_offset,
          period_start: anchor_date + elapsed_cycles * cycle_days
        }
      rescue KeyError, Date::Error, ArgumentError
        nil
      end
  end
end

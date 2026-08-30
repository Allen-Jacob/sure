# frozen_string_literal: true

# Exposes the upcoming paycheck already calculated for Sure's web dashboard.
# Calendar credentials and payroll configuration never leave the server.
class Api::V1::PaycheckController < Api::V1::BaseController
  before_action :ensure_read_scope

  def show
    user = current_resource_owner
    family = user.family
    accounts = family.accounts.accessible_by(user).visible
    paycheck = Dashboard::FinancialSnapshot.new(
      family: family,
      user: user,
      accounts: accounts
    ).paycheck_summary

    render json: {
      currency: family.currency,
      paycheck: paycheck && paycheck_json(paycheck)
    }
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def paycheck_json(paycheck)
      {
        name: paycheck.fetch(:name),
        amount: paycheck.fetch(:amount).as_json,
        last_date: paycheck.fetch(:last_date),
        next_date: paycheck.fetch(:next_date),
        days_remaining: paycheck.fetch(:days_remaining),
        estimated: paycheck.fetch(:estimated),
        source: paycheck_source(paycheck),
        scheduled_hours: paycheck[:scheduled_hours]&.to_f,
        pay_period_start: paycheck[:pay_period_start],
        pay_period_end: paycheck[:pay_period_end]
      }
    end

    def paycheck_source(paycheck)
      return "agendrix" if paycheck[:calendar]
      return "configured" if paycheck[:configured]
      return "inferred" if paycheck[:estimated]

      "recurring"
    end
end

class Api::V1::UpcomingController < Api::V1::BaseController
  before_action :ensure_scope

  def index
    from = params[:from].present? ? Date.iso8601(params[:from]) : Date.current
    to = params[:to].present? ? Date.iso8601(params[:to]) : from + 90
    raise ArgumentError unless to >= from && (to - from) <= 366

    account = current_resource_owner.accessible_accounts.find(params[:account_id]) if params[:account_id].present?
    occurrences = RecurringTransaction::Upcoming.new(user: current_resource_owner, account: account, from: from, to: to).occurrences
    render json: { upcoming: occurrences.map { |occurrence| occurrence_json(occurrence) } }
  rescue ArgumentError, TypeError
    render json: { error: "invalid_date", message: "Use ISO dates and a range of at most 366 days." }, status: :unprocessable_entity
  end

  def update
    user = current_resource_owner
    series = user.family.recurring_transactions.accessible_by(user)
    occurrence = user.family.recurring_occurrences.where(recurring_transaction_id: series.select(:id)).find(params[:id])
    account_ids = [ occurrence.recurring_transaction.account_id, occurrence.recurring_transaction.destination_account_id ].compact
    raise ActiveRecord::RecordNotFound unless user.family.accounts.writable_by(user).where(id: account_ids).count == account_ids.uniq.size

    unless occurrence.scheduled?
      return render json: { error: "closed_occurrence", message: "Only scheduled occurrences can be edited." }, status: :unprocessable_entity
    end

    amount = params[:expected_amount]
    unless amount.is_a?(String) || amount.is_a?(Numeric)
      return render json: { error: "invalid_amount", message: "A nonnegative expected_amount is required." }, status: :unprocessable_entity
    end

    amount = BigDecimal(amount.to_s, exception: false)
    unless amount&.finite? && amount >= 0
      return render json: { error: "invalid_amount", message: "A nonnegative expected_amount is required." }, status: :unprocessable_entity
    end

    if occurrence.update(expected_amount: amount)
      render json: occurrence_json(occurrence)
    else
      render json: { error: "validation_failed", errors: occurrence.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private
    def ensure_scope
      authorize_scope!(action_name == "update" ? :write : :read)
    end

    def occurrence_json(occurrence)
      series = occurrence.recurring_transaction
      {
        id: occurrence.id,
        recurring_transaction_id: series.id,
        name: series.display_name,
        date: occurrence.effective_due_on,
        expected_amount: occurrence.resolved_expected_amount.to_s("F"),
        currency: occurrence.currency,
        direction: series.transfer? ? "transfer" : (series.amount.negative? ? "income" : "expense"),
        account_id: series.account_id,
        destination_account_id: series.destination_account_id,
        amount_overridden: occurrence.expected_amount.present?,
        status: occurrence.status
      }
    end
end

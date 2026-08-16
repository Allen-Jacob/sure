# frozen_string_literal: true

class Api::V1::TransfersController < Api::V1::BaseController
  include Pagy::Backend
  include Api::V1::TransferDecisionFiltering

  before_action :ensure_read_scope, only: [ :index, :show ]
  before_action :ensure_write_scope, only: :create
  before_action :set_transfer, only: :show

  def index
    transfers_query = apply_transfer_decision_filters(transfers_scope, status_model: Transfer).order(created_at: :desc)
    @per_page = safe_per_page_param

    @pagy, @transfers = pagy(
      transfers_query,
      page: safe_page_param,
      limit: @per_page
    )

    render :index
  rescue Api::V1::TransferDecisionFiltering::InvalidFilterError => e
    render_validation_error(e.message)
  end

  def show
    render :show
  end

  def create
    attributes = transfer_params
    source_account_id = attributes[:from_account_id]
    destination_account_id = attributes[:to_account_id]

    unless source_account_id.present? && destination_account_id.present?
      return render_validation_error("Source and destination account IDs are required")
    end

    if source_account_id == destination_account_id
      return render_validation_error("Source and destination accounts must be different")
    end

    amount = parse_positive_decimal(attributes[:amount], "amount")
    date = parse_transfer_date(attributes[:date])
    exchange_rate = parse_optional_positive_decimal(attributes[:exchange_rate], "exchange_rate")
    return if performed?

    writable_accounts = current_resource_owner.family.accounts.writable_by(current_resource_owner)
    source_account = writable_accounts.find(source_account_id)
    destination_account = writable_accounts.find(destination_account_id)

    @transfer = Transfer::Creator.new(
      family: current_resource_owner.family,
      source_account_id: source_account.id,
      destination_account_id: destination_account.id,
      date: date,
      amount: amount,
      exchange_rate: exchange_rate
    ).create

    render :show, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render_validation_error(e.record.errors.full_messages.to_sentence.presence || "Transfer could not be created")
  rescue Money::ConversionError
    render_validation_error("An exchange rate is required for these account currencies")
  rescue ArgumentError => e
    render_validation_error(e.message)
  end

  private

    def set_transfer
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @transfer = transfers_scope.find(params[:id])
    end

    def transfers_scope
      transfer_decision_scope(Transfer)
    end

    def ensure_write_scope
      authorize_scope!(:write)
    end

    def transfer_params
      params.require(:transfer).permit(:from_account_id, :to_account_id, :date, :amount, :exchange_rate)
    end

    def parse_transfer_date(value)
      raise ArgumentError, "date is required" if value.blank?

      Date.iso8601(value.to_s)
    rescue Date::Error
      raise ArgumentError, "date must be an ISO 8601 date"
    end

    def parse_positive_decimal(value, name)
      raise ArgumentError, "#{name} is required" if value.blank?

      decimal = BigDecimal(value.to_s, exception: false)
      raise ArgumentError, "#{name} must be a valid positive number" unless decimal&.positive?

      decimal
    end

    def parse_optional_positive_decimal(value, name)
      return nil if value.blank?

      parse_positive_decimal(value, name)
    end
end

class Settings::PreferencesController < ApplicationController
  layout "settings"

  PAY_CYCLE_DAYS = [ 7, 14, 15, 28, 30, 31 ].freeze
  class InvalidPaycheckAllocation < ArgumentError; end

  def show
    @user = Current.user
    load_cash_plan_options
  end

  # Writes per-user preferences stored in the JSONB `users.preferences` column.
  # This lets the toggle and cash-plan forms submit without going through the
  # broader UsersController#update flow, which expects a full user payload.
  def update
    @user = Current.user

    if params.key?(:dashboard_cash_plan)
      update_cash_plan_preferences
      return
    end

    user_params = params.permit(user: [ :preview_features_enabled ]).fetch(:user, {})

    @user.transaction do
      @user.lock!
      updated_prefs = (@user.preferences || {}).deep_dup
      if user_params.key?(:preview_features_enabled)
        updated_prefs["preview_features_enabled"] =
          ActiveModel::Type::Boolean.new.cast(user_params[:preview_features_enabled])
      end
      @user.update!(preferences: updated_prefs)
    end
    redirect_to settings_preferences_path
  end

  private
    def update_cash_plan_preferences
      @user.update_dashboard_cash_plan_settings(normalized_cash_plan_settings)
      redirect_to settings_preferences_path, notice: t(".cash_plan_saved")
    rescue InvalidPaycheckAllocation
      redirect_to settings_preferences_path, alert: t(".cash_plan_invalid_allocation")
    rescue ArgumentError
      redirect_to settings_preferences_path, alert: t(".cash_plan_invalid_schedule")
    end

    def normalized_cash_plan_settings
      submitted = params.require(:dashboard_cash_plan).permit(
        :primary_credit_card_id,
        :next_pay_date,
        :expected_pay_amount,
        :pay_cycle_days,
        depository_account_ids: [],
        credit_card_account_ids: [],
        payroll_category_ids: [],
        paycheck_allocations: {}
      )

      accounts = cash_plan_accounts
      depository_ids = allowed_ids(
        submitted[:depository_account_ids],
        accounts.select { |account| account.accountable_type == "Depository" }
      )
      credit_card_ids = allowed_ids(
        submitted[:credit_card_account_ids],
        accounts.select { |account| account.accountable_type == "CreditCard" }
      )
      payroll_category_ids = allowed_ids(submitted[:payroll_category_ids], Current.family.categories)

      settings = {}
      settings["depository_account_ids"] = depository_ids if depository_ids.any?
      settings["credit_card_account_ids"] = credit_card_ids if credit_card_ids.any?
      settings["payroll_category_ids"] = payroll_category_ids if payroll_category_ids.any?

      primary_card_id = submitted[:primary_credit_card_id].to_s.presence
      allowed_credit_card_ids = accounts.select { |account| account.accountable_type == "CreditCard" }.map { |account| account.id.to_s }
      if primary_card_id.in?(allowed_credit_card_ids) && (credit_card_ids.empty? || primary_card_id.in?(credit_card_ids))
        settings["primary_credit_card_id"] = primary_card_id
      end

      pay_cycle_days = submitted[:pay_cycle_days].to_i
      settings["pay_cycle_days"] = pay_cycle_days if pay_cycle_days.in?(PAY_CYCLE_DAYS)
      add_paycheck_allocations!(settings, submitted, accounts:, depository_ids:)
      add_manual_pay_schedule!(settings, submitted)
      settings
    end

    def add_paycheck_allocations!(settings, submitted, accounts:, depository_ids:)
      allowed_accounts = accounts.select { |account| account.accountable_type == "Depository" }
      return if allowed_accounts.empty?

      effective_ids = depository_ids.presence || allowed_accounts.map { |account| account.id.to_s }
      unless submitted.key?(:paycheck_allocations)
        base = (100.to_d / effective_ids.size).round(1, :down)
        remaining = 100.to_d
        settings["paycheck_allocations"] = effective_ids.each_with_index.to_h do |account_id, index|
          percentage = index == effective_ids.length - 1 ? remaining : base
          remaining -= percentage
          [ account_id, percentage.to_s("F") ]
        end
        return
      end

      raw_allocations = submitted[:paycheck_allocations]&.to_h || {}
      allocations = effective_ids.to_h do |account_id|
        raw_value = raw_allocations[account_id].to_s.strip
        percentage = raw_value.present? ? BigDecimal(raw_value.tr(",", ".")) : 0.to_d
        raise InvalidPaycheckAllocation unless percentage.between?(0, 100)

        [ account_id, percentage ]
      rescue ArgumentError
        raise InvalidPaycheckAllocation
      end

      positive_allocations = allocations.select { |_account_id, percentage| percentage.positive? }
      total = positive_allocations.values.sum(0.to_d)
      raise InvalidPaycheckAllocation unless total == 100.to_d

      settings["paycheck_allocations"] = positive_allocations.transform_values { |percentage| percentage.to_s("F") }
    end

    def add_manual_pay_schedule!(settings, submitted)
      next_pay_date = submitted[:next_pay_date].to_s.strip
      expected_amount = submitted[:expected_pay_amount].to_s.strip
      return if next_pay_date.blank? && expected_amount.blank?
      raise ArgumentError if next_pay_date.blank? || expected_amount.blank?

      parsed_date = Date.iso8601(next_pay_date)
      parsed_amount = BigDecimal(expected_amount.tr(",", "."))
      raise ArgumentError unless parsed_amount.positive?

      settings["next_pay_date"] = parsed_date.iso8601
      settings["expected_pay_amount"] = parsed_amount.to_s("F")
    rescue Date::Error, ArgumentError
      raise ArgumentError
    end

    def allowed_ids(submitted_ids, allowed_records)
      allowed = allowed_records.map { |record| record.id.to_s }
      Array(submitted_ids).reject(&:blank?).map(&:to_s) & allowed
    end

    def load_cash_plan_options
      @cash_plan_accounts = cash_plan_accounts
      @cash_plan_depository_accounts = @cash_plan_accounts.select { |account| account.accountable_type == "Depository" }
      @cash_plan_credit_card_accounts = @cash_plan_accounts.select { |account| account.accountable_type == "CreditCard" }
      @cash_plan_categories = Current.family.categories.alphabetically_by_hierarchy.to_a
      @cash_plan_settings = @user.dashboard_cash_plan_settings
      @selected_cash_plan_depository_ids = selected_account_ids("depository_account_ids", @cash_plan_depository_accounts)
      @selected_cash_plan_credit_card_ids = selected_account_ids("credit_card_account_ids", @cash_plan_credit_card_accounts)
      @selected_payroll_category_ids = valid_setting_ids("payroll_category_ids", @cash_plan_categories)
      @cash_plan_paycheck_allocations = paycheck_allocation_values
    end

    def cash_plan_accounts
      @cash_plan_accounts ||= @user.accessible_accounts
                                    .visible
                                    .where(currency: Current.family.primary_currency_code)
                                    .where(accountable_type: %w[Depository CreditCard])
                                    .order(:name)
                                    .to_a
    end

    def selected_account_ids(key, accounts)
      selected = valid_setting_ids(key, accounts)
      selected.any? ? selected : accounts.map { |account| account.id.to_s }
    end

    def valid_setting_ids(key, records)
      configured = Array(@cash_plan_settings[key]).map(&:to_s)
      configured & records.map { |record| record.id.to_s }
    end

    def paycheck_allocation_values
      configured = @cash_plan_settings["paycheck_allocations"]
      if configured.is_a?(Hash) && configured.values.sum { |value| value.to_d } == 100.to_d
        return configured.transform_keys(&:to_s)
      end

      selected_accounts = @cash_plan_depository_accounts.select do |account|
        account.id.to_s.in?(@selected_cash_plan_depository_ids)
      end
      return {} if selected_accounts.empty?

      base = (100.to_d / selected_accounts.size).round(1, :down)
      remaining = 100.to_d
      selected_accounts.each_with_index.to_h do |account, index|
        percentage = index == selected_accounts.length - 1 ? remaining : base
        remaining -= percentage
        [ account.id.to_s, percentage.to_s("F") ]
      end
    end
end

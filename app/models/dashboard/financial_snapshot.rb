module Dashboard
  class FinancialSnapshot
    PAYROLL_KEYWORDS = %w[
      salary payroll paycheck wages wage employer
      salaire paie paye employeur rémunération remuneration
    ].freeze
    REFUND_KEYWORDS = %w[refund reimbursement remboursement rebate].freeze
    DEFAULT_PAY_CYCLE_DAYS = 14
    RECENT_PAY_LOOKBACK = 120.days

    def initialize(family:, user:, accounts:, today: Date.current)
      @family = family
      @user = user
      @accounts = accounts.to_a
      @today = today
      @currency = family.primary_currency_code
      @settings = user.dashboard_cash_plan_settings
      configured_cycle = @settings["pay_cycle_days"].to_i
      @pay_cycle_days = configured_cycle.between?(7, 31) ? configured_cycle : DEFAULT_PAY_CYCLE_DAYS
    end

    def to_h
      @to_h ||= begin
        pay = paycheck
        period_start = pay&.fetch(:last_date) || (@today - @pay_cycle_days)
        period_end = pay&.fetch(:next_date) || (@today + @pay_cycle_days)
        period_end = @today + 1 if period_end <= @today

        spending = spending_snapshot(period_start)
        goals = prepared_goals
        reserved = reserved_for_goals
        planned = planned_payments(period_end)
        available = available_snapshot(reserved:, planned:)
        card = credit_card_snapshot(reserved:, planned:)

        {
          currency: @currency,
          ignored_account_count: ignored_account_count,
          paycheck: pay,
          spending: spending,
          available: available,
          credit_card: card,
          budget: budget_snapshot(available:, period_end:),
          goals: goals.first(3),
          allocation: allocation_snapshot(pay:),
          purchases: purchase_snapshots(goals:, available:),
          categories: category_snapshot(spending.fetch(:entries)),
          review: review_snapshot,
          planned_payments: planned
        }
      end
    end

    # Public, privacy-safe entry point for API clients that only need the
    # upcoming paycheck. The Agendrix calendar URL and hourly-rate settings
    # remain internal to the server.
    def paycheck_summary
      paycheck
    end

    private
      def money(amount)
        Money.new(amount.to_d, @currency)
      end

      def recurring_scope
        @recurring_scope ||= @family.recurring_transactions
                                             .accessible_by(@user)
                                             .where(currency: @currency)
                                             .where(account_id: cash_plan_account_ids)
                                             .includes(:merchant, :account, :destination_account)
      end

      def transaction_entries
        @transaction_entries ||= Entry
          .where(account_id: cash_plan_account_ids, entryable_type: "Transaction", excluded: false)
          .excluding_split_parents
          .excluding_pending
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")
          .where.not(transactions: { kind: Transaction::BUDGET_EXCLUDED_KINDS })
      end

      def paycheck
        configured_paycheck || calendar_paycheck || recurring_paycheck || inferred_paycheck
      end

      def configured_paycheck
        next_date = Date.iso8601(@settings.fetch("next_pay_date").to_s)
        amount = BigDecimal(@settings.fetch("expected_pay_amount").to_s)
        return unless amount.positive?

        if next_date < @today
          elapsed_cycles = ((@today - next_date).to_i.fdiv(@pay_cycle_days)).ceil
          next_date += elapsed_cycles * @pay_cycle_days
        end
        {
          name: I18n.t("pages.dashboard.cash_plan.paycheck_configured"),
          amount: money(amount),
          last_date: next_date - @pay_cycle_days,
          next_date: next_date,
          days_remaining: (next_date - @today).to_i,
          estimated: false,
          configured: true
        }
      rescue KeyError, Date::Error, ArgumentError
        nil
      end

      def calendar_paycheck
        calendar_url = @settings.fetch("work_calendar_url").to_s
        hourly_rate = BigDecimal(@settings.fetch("hourly_pay_rate").to_s)
        anchor_date = Date.iso8601(@settings.fetch("pay_period_anchor_date").to_s)
        payday_offset = Integer(@settings.fetch("payday_offset_days").to_s, 10)
        return unless Dashboard::PayrollCalendar.valid_url?(calendar_url)
        return unless hourly_rate.finite? && hourly_rate.positive? && payday_offset.between?(0, 31)

        first_payday = anchor_date + @pay_cycle_days - 1 + payday_offset
        elapsed_cycles = [ ((@today - first_payday).to_i.fdiv(@pay_cycle_days)).ceil, 0 ].max
        period_start = anchor_date + elapsed_cycles * @pay_cycle_days
        period_end = period_start + @pay_cycle_days - 1
        next_date = period_end + payday_offset
        scheduled_hours = Dashboard::PayrollCalendar.new(url: calendar_url).hours_between(period_start, period_end)

        {
          name: I18n.t("pages.dashboard.cash_plan.paycheck_agendrix"),
          amount: money(hourly_rate * scheduled_hours),
          last_date: next_date - @pay_cycle_days,
          next_date: next_date,
          days_remaining: (next_date - @today).to_i,
          estimated: true,
          configured: true,
          calendar: true,
          scheduled_hours: scheduled_hours,
          pay_period_start: period_start,
          pay_period_end: period_end
        }
      rescue KeyError, Date::Error, ArgumentError, Dashboard::PayrollCalendar::Error
        nil
      end

      def recurring_paycheck
        candidates = recurring_scope.active
                                    .where(destination_account_id: nil)
                                    .where("amount < 0")
                                    .to_a
        return if candidates.empty?

        recurring = candidates.max_by do |candidate|
          [ payroll_text?(recurring_name(candidate)) ? 1 : 0, candidate.amount.abs ]
        end
        return unless payroll_text?(recurring_name(recurring)) || candidates.one?

        next_date = normalize_recurring_date(recurring.next_expected_date, recurring.expected_day_of_month)
        {
          name: recurring_name(recurring),
          amount: money((recurring.expected_amount_avg || recurring.amount).abs),
          last_date: recurring.last_occurrence_date,
          next_date: next_date,
          days_remaining: (next_date - @today).to_i,
          estimated: false
        }
      end

      def inferred_paycheck
        recent = transaction_entries
          .where("entries.amount < 0")
          .where(date: (@today - RECENT_PAY_LOOKBACK)..@today)
          .includes(entryable: [ :category, :merchant ])
          .order(date: :desc)
          .limit(250)
          .to_a

        candidates = recent.select { |entry| payroll_entry?(entry) }
        return if candidates.empty?

        latest = candidates.max_by(&:date)
        matching = candidates.select { |entry| same_pay_source?(entry, latest) }.sort_by(&:date)
        interval = inferred_pay_interval(matching.map(&:date))
        next_date = latest.date
        next_date += interval while next_date <= @today
        recent_amounts = matching.last(3).map { |entry| entry.amount.abs }

        {
          name: latest.name,
          amount: money(recent_amounts.sum / recent_amounts.size),
          last_date: latest.date,
          next_date: next_date,
          days_remaining: (next_date - @today).to_i,
          estimated: true
        }
      end

      def recurring_name(recurring)
        recurring.merchant&.name.presence || recurring.name.presence || I18n.t("pages.dashboard.cash_plan.paycheck_fallback")
      end

      def payroll_entry?(entry)
        transaction = entry.entryable
        category = transaction.category
        return true if payroll_category_ids.include?(category&.id) || payroll_category_ids.include?(category&.parent_id)

        payroll_text?([ entry.name, transaction.category&.name, transaction.category&.parent&.name ].compact.join(" "))
      end

      def payroll_text?(text)
        normalized = I18n.transliterate(text.to_s).downcase
        PAYROLL_KEYWORDS.any? { |keyword| normalized.include?(keyword) }
      end

      def same_pay_source?(entry, latest)
        entry.name.casecmp?(latest.name) ||
          (entry.entryable.category_id.present? && entry.entryable.category_id == latest.entryable.category_id)
      end

      def inferred_pay_interval(dates)
        gaps = dates.each_cons(2).map { |left, right| (right - left).to_i }.select { |gap| gap.between?(7, 45) }
        return @pay_cycle_days if gaps.empty?

        sorted = gaps.sort
        sorted[sorted.length / 2]
      end

      def normalize_recurring_date(date, expected_day)
        candidate = date
        while candidate < @today
          candidate = RecurringTransaction.calculate_next_expected_date_for(candidate, expected_day)
        end
        candidate
      end

      def spending_snapshot(period_start)
        entries = expense_entries_between(period_start, @today).to_a
        total = entries.sum(&:amount)
        days_elapsed = [ (@today - period_start).to_i + 1, 1 ].max
        previous_end = period_start - 1
        previous_start = previous_end - (days_elapsed - 1)
        previous_total = expense_entries_between(previous_start, previous_end).sum(:amount)

        change_percent = if previous_total.to_d.zero?
          nil
        else
          (((total - previous_total) / previous_total) * 100).round
        end

        {
          total: money(total),
          days_elapsed: days_elapsed,
          period_start: period_start,
          previous_total: money(previous_total),
          change_percent: change_percent,
          entries: entries
        }
      end

      def expense_entries_between(start_date, end_date)
        transaction_entries.where(date: start_date..end_date).where("entries.amount > 0")
      end

      def reserved_for_goals
        rows = GoalAccount
          .joins(:goal)
          .where(account_id: depository_accounts.map(&:id))
          .where.not(goals: { state: "archived" })
          .pluck(:account_id, :allocated_amount)
          .group_by(&:first)

        total = depository_accounts.sum do |account|
          allocations = rows.fetch(account.id, [])
          next 0.to_d if allocations.empty?

          fixed = allocations.sum { |(_, amount)| amount.to_d }
          requested = allocations.any? { |(_, amount)| amount.nil? } ? account.balance.to_d : fixed
          [ requested, [ account.balance.to_d, 0.to_d ].max ].min
        end

        money(total)
      end

      def planned_payments(period_end)
        credit_card_ids = credit_card_accounts.map(&:id)
        items = recurring_scope.active.where("amount > 0").filter_map do |recurring|
          due_date = normalize_recurring_date(recurring.next_expected_date, recurring.expected_day_of_month)
          next if due_date > period_end

          is_card_payment = recurring.destination_account_id.in?(credit_card_ids)
          next if recurring.transfer? && !is_card_payment

          {
            name: recurring_name(recurring),
            amount: money(recurring.amount.abs),
            due_date: due_date,
            card_payment: is_card_payment
          }
        end

        non_card_total = items.reject { |item| item[:card_payment] }.sum { |item| item[:amount].amount }
        {
          items: items.sort_by { |item| item[:due_date] },
          total: money(non_card_total),
          count: items.count { |item| !item[:card_payment] }
        }
      end

      def available_snapshot(reserved:, planned:)
        cash = depository_accounts.sum(&:balance)
        card_debt = credit_card_accounts.sum { |account| [ account.balance.to_d, 0.to_d ].max }
        amount = cash - card_debt - planned.fetch(:total).amount - reserved.amount

        {
          amount: money(amount),
          cash: money(cash),
          card_debt: money(card_debt),
          planned: planned.fetch(:total),
          reserved: reserved
        }
      end

      def credit_card_snapshot(reserved:, planned:)
        account = credit_card_accounts.find { |card| card.id.to_s == @settings["primary_credit_card_id"].to_s }
        account ||= credit_card_accounts.max_by { |card| card.balance.to_d }
        return {
          account: nil,
          current_balance: money(0),
          statement_balance: nil,
          due_date: nil,
          available_to_repay: money(0)
        } unless account

        statement = @family.account_statements
                           .where(account_id: account.id)
                           .where.not(closing_balance: nil)
                           .order(period_end_on: :desc, created_at: :desc)
                           .first
        card_recurring = recurring_scope.active
                                        .where("destination_account_id = :id OR account_id = :id", id: account.id)
                                        .where("amount > 0")
                                        .min_by { |item| normalize_recurring_date(item.next_expected_date, item.expected_day_of_month) }
        cash_after_commitments = depository_accounts.sum(&:balance) - reserved.amount - planned.fetch(:total).amount

        {
          account: account,
          current_balance: money([ account.balance.to_d, 0.to_d ].max),
          statement_balance: statement ? money(statement.closing_balance.abs) : nil,
          due_date: card_recurring && normalize_recurring_date(card_recurring.next_expected_date, card_recurring.expected_day_of_month),
          available_to_repay: money([ cash_after_commitments, 0.to_d ].max)
        }
      end

      def budget_snapshot(available:, period_end:)
        days = [ (period_end - @today).to_i, 1 ].max
        spendable = [ available.fetch(:amount).amount, 0.to_d ].max
        {
          total: money(spendable),
          daily: money(spendable / days),
          days_remaining: days
        }
      end

      def prepared_goals
        @prepared_goals ||= Goal.active_prepared_for(@family).select { |goal| goal.currency == @currency }
      end

      def allocation_snapshot(pay:)
        pay_amount = pay&.fetch(:amount)&.amount.to_d
        percentages, configured = paycheck_allocation_percentages
        allocated_amount = 0.to_d

        {
          total: money(pay_amount),
          configured: configured,
          items: percentages.each_with_index.map do |(account, percent), index|
            amount = if index == percentages.length - 1
              pay_amount - allocated_amount
            else
              pay_amount * percent / 100
            end
            allocated_amount += amount

            {
              account: account,
              account_name: account.name,
              amount: money(amount),
              percent: percent
            }
          end
        }
      end

      def paycheck_allocation_percentages
        configured = @settings["paycheck_allocations"]
        if configured.is_a?(Hash)
          percentages = depository_accounts.filter_map do |account|
            percent = configured[account.id.to_s].to_d
            [ account, percent ] if percent.positive?
          end
          return [ percentages, true ] if percentages.any? && percentages.sum(&:last) == 100.to_d
        end

        return [ [], false ] if depository_accounts.empty?

        base = (100.to_d / depository_accounts.size).round(1, :down)
        remaining = 100.to_d
        percentages = depository_accounts.each_with_index.map do |account, index|
          percent = index == depository_accounts.length - 1 ? remaining : base
          remaining -= percent
          [ account, percent ]
        end
        [ percentages, false ]
      end

      def purchase_snapshots(goals:, available:)
        goals.select { |goal| goal.target_date.present? && goal.target_date >= @today }
             .sort_by(&:target_date)
             .first(3)
             .map do |goal|
          {
            goal: goal,
            price: goal.target_amount_money,
            saved: money([ goal.current_balance, goal.target_amount ].min),
            impact: money(available.fetch(:amount).amount - goal.remaining_amount)
          }
        end
      end

      def category_snapshot(entries)
        grouped = entries.group_by do |entry|
          category = entry.entryable.category
          category&.parent || category
        end
        total = entries.sum(&:amount).to_d

        grouped.map do |category, category_entries|
          amount = category_entries.sum(&:amount).to_d
          {
            name: category&.display_name || Category.uncategorized.display_name,
            color: category&.color || "var(--color-gray-400)",
            amount: money(amount),
            percent: total.positive? ? ((amount / total) * 100).round : 0
          }
        end.sort_by { |item| -item[:amount].amount }.first(5)
      end

      def review_snapshot
        recent = Entry
          .where(account_id: cash_plan_account_ids, entryable_type: "Transaction", excluded: false)
          .excluding_split_parents
          .where(date: (@today - 90.days)..@today)
          .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id")

        uncategorized = recent.where(transactions: { category_id: nil })
                              .where.not(transactions: { kind: Transaction::TRANSFER_KINDS })
                              .count
        duplicates = recent.where("transactions.extra ? 'potential_posted_match'")
                           .where("COALESCE((transactions.extra -> 'potential_posted_match' ->> 'dismissed')::boolean, false) = false")
                           .count
        missing_refunds = recurring_scope.active.where("amount < 0 AND next_expected_date < ?", @today).count do |recurring|
          normalized = I18n.transliterate(recurring_name(recurring)).downcase
          REFUND_KEYWORDS.any? { |keyword| normalized.include?(keyword) }
        end

        {
          uncategorized: uncategorized,
          duplicates: duplicates,
          missing_refunds: missing_refunds,
          total: uncategorized + duplicates + missing_refunds
        }
      end

      def depository_accounts
        @depository_accounts ||= configured_accounts("Depository", "depository_account_ids")
      end

      def credit_card_accounts
        @credit_card_accounts ||= configured_accounts("CreditCard", "credit_card_account_ids")
      end

      def configured_accounts(accountable_type, setting_key)
        candidates = @accounts.select do |account|
          account.currency == @currency && account.accountable_type == accountable_type
        end
        configured_ids = Array(@settings[setting_key]).map(&:to_s)
        return candidates if configured_ids.empty?

        selected = candidates.select { |account| account.id.to_s.in?(configured_ids) }
        selected.any? ? selected : candidates
      end

      def cash_plan_account_ids
        @cash_plan_account_ids ||= (depository_accounts + credit_card_accounts).map(&:id)
      end

      def payroll_category_ids
        @payroll_category_ids ||= begin
          allowed_ids = @family.categories.pluck(:id).index_by(&:to_s)
          Array(@settings["payroll_category_ids"])
            .filter_map { |configured_id| allowed_ids[configured_id.to_s] }
            .to_set
        end
      end

      def ignored_account_count
        @accounts.count { |account| account.currency != @currency }
      end
  end
end

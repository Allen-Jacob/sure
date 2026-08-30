module Reports
  class MonthComparison
    attr_reader :primary_period, :comparison_period

    def initialize(income_statement:, primary_month:, comparison_month:, currency:, today: Date.current)
      @income_statement = income_statement
      @primary_month = primary_month.beginning_of_month
      @comparison_month = comparison_month.beginning_of_month
      @currency = currency
      @today = today
      @through_day = current_month_selected? ? today.day : nil
      @primary_period = period_for(@primary_month)
      @comparison_period = period_for(@comparison_month)
    end

    def primary
      @primary ||= period_snapshot(primary_period)
    end

    def comparison
      @comparison ||= period_snapshot(comparison_period)
    end

    def metrics
      @metrics ||= [
        money_metric(:income, primary[:income], comparison[:income], favorable_direction: :up),
        money_metric(:expenses, primary[:expenses], comparison[:expenses], favorable_direction: :down),
        money_metric(:net_savings, primary[:net_savings], comparison[:net_savings], favorable_direction: :up),
        percentage_metric(:savings_rate, primary[:savings_rate], comparison[:savings_rate], favorable_direction: :up)
      ]
    end

    def income_categories
      category_comparison(primary[:income_categories], comparison[:income_categories])
    end

    def expense_categories
      category_comparison(primary[:expense_categories], comparison[:expense_categories])
    end

    def partial_period?
      @through_day.present?
    end

    def through_day
      @through_day
    end

    private
      def current_month_selected?
        current_month = @today.beginning_of_month
        @primary_month == current_month || @comparison_month == current_month
      end

      def period_for(month)
        end_date = month.end_of_month
        if @through_day
          end_date = [ end_date, month + (@through_day - 1).days ].min
        end
        Period.custom(start_date: month, end_date: end_date)
      end

      def period_snapshot(period)
        income_totals = @income_statement.income_totals(period: period)
        expense_totals = @income_statement.expense_totals(period: period)
        income = money(income_totals.total)
        expenses = money(expense_totals.total)
        net_savings = income - expenses

        {
          income: income,
          expenses: expenses,
          net_savings: net_savings,
          savings_rate: income.amount.positive? ? ((net_savings.amount / income.amount) * 100).round(1) : nil,
          income_categories: parent_category_totals(income_totals),
          expense_categories: parent_category_totals(expense_totals)
        }
      end

      def parent_category_totals(period_total)
        period_total.category_totals
                    .reject { |total| total.category.subcategory? || total.total.to_d.zero? }
                    .index_by { |total| category_key(total.category) }
      end

      def category_key(category)
        return "uncategorized" if category.uncategorized?
        return "other_investments" if category.other_investments?

        category.id.to_s
      end

      def category_comparison(primary_totals, comparison_totals)
        (primary_totals.keys | comparison_totals.keys).map do |key|
          primary_total = primary_totals[key]
          comparison_total = comparison_totals[key]
          primary_amount = money(primary_total&.total || 0)
          comparison_amount = money(comparison_total&.total || 0)

          {
            category: primary_total&.category || comparison_total.category,
            primary: primary_amount,
            comparison: comparison_amount,
            delta: primary_amount - comparison_amount,
            percent_change: percent_change(primary_amount.amount, comparison_amount.amount)
          }
        end.sort_by { |row| -[ row[:primary].amount, row[:comparison].amount ].max }
      end

      def money_metric(key, primary_value, comparison_value, favorable_direction:)
        delta = primary_value - comparison_value
        {
          key: key,
          primary: primary_value,
          comparison: comparison_value,
          delta: delta,
          percent_change: percent_change(primary_value.amount, comparison_value.amount),
          favorable: favorable?(delta.amount, favorable_direction),
          percentage: false
        }
      end

      def percentage_metric(key, primary_value, comparison_value, favorable_direction:)
        delta = primary_value && comparison_value ? (primary_value - comparison_value).round(1) : nil
        {
          key: key,
          primary: primary_value,
          comparison: comparison_value,
          delta: delta,
          percent_change: delta,
          favorable: delta && favorable?(delta, favorable_direction),
          percentage: true
        }
      end

      def percent_change(primary_amount, comparison_amount)
        return if comparison_amount.to_d.zero?

        (((primary_amount.to_d - comparison_amount.to_d) / comparison_amount.to_d.abs) * 100).round(1)
      end

      def favorable?(delta, direction)
        direction == :up ? delta >= 0 : delta <= 0
      end

      def money(amount)
        Money.new(amount.to_d, @currency)
      end
  end
end

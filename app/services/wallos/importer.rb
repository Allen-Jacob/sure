module Wallos
  class Importer
    Result = Data.define(:imported_count, :inactive_count)

    def initialize(connection, client: nil)
      @connection = connection
      @client = client || Client.new(base_url: connection.base_url, api_key: connection.api_key)
    end

    def import
      subscriptions = @client.subscriptions
      currencies = @client.currencies
      imported_ids = []

      RecurringTransaction.transaction do
        subscriptions.each do |subscription|
          recurring_transaction = import_subscription(subscription, currencies)
          imported_ids << recurring_transaction.source_id
        end

        stale_scope = @connection.family.recurring_transactions.where(source: "wallos")
        stale_scope = stale_scope.where.not(source_id: imported_ids) if imported_ids.any?
        stale_scope.update_all(status: "inactive", updated_at: Time.current)
        @connection.update!(last_synced_at: Time.current)
      end

      Result.new(imported_count: imported_ids.size, inactive_count: subscriptions.count { |item| truthy?(item["inactive"]) })
    end

    private

      def import_subscription(subscription, currencies)
        source_id = subscription.fetch("id").to_s
        next_date = Date.iso8601(subscription.fetch("next_payment"))
        currency = currencies.fetch(subscription.fetch("currency_id").to_s).fetch("code").to_s.upcase
        amount = BigDecimal(subscription.fetch("price").to_s)

        recurring_transaction = @connection.family.recurring_transactions.find_or_initialize_by(
          source: "wallos",
          source_id: source_id
        )

        if recurring_transaction.new_record?
          recurring_transaction = matching_recurring_transaction(subscription, amount, currency) || recurring_transaction
        end

        recurring_transaction.assign_attributes(
          account: @connection.account,
          merchant: nil,
          name: subscription.fetch("name"),
          amount: amount,
          currency: currency,
          expected_day_of_month: next_date.day,
          last_occurrence_date: last_occurrence_date(subscription, next_date),
          next_expected_date: next_date,
          status: truthy?(subscription["inactive"]) ? "inactive" : "active",
          occurrence_count: [ recurring_transaction.occurrence_count.to_i, 1 ].max,
          manual: true,
          source: "wallos",
          source_id: source_id,
          source_metadata: {
            "payer" => subscription["payer_user_name"],
            "payment_method" => subscription["payment_method_name"],
            "category" => subscription["category_name"],
            "cycle" => subscription["cycle"],
            "frequency" => subscription["frequency"],
            "auto_renew" => subscription["auto_renew"]
          }.compact
        )
        recurring_transaction.save!
        recurring_transaction
      rescue Date::Error, KeyError, ArgumentError => error
        raise Client::Error, "Invalid Wallos subscription #{source_id || subscription['id']}: #{error.message}"
      end

      def matching_recurring_transaction(subscription, amount, currency)
        @connection.family.recurring_transactions.find_by(
          account: @connection.account,
          merchant_id: nil,
          source: nil,
          name: subscription.fetch("name"),
          amount: amount,
          currency: currency
        )
      end

      def last_occurrence_date(subscription, next_date)
        frequency = [ subscription["frequency"].to_i, 1 ].max
        previous_date =
          case subscription["cycle"].to_i
          when 1 then next_date - frequency.days
          when 2 then next_date - frequency.weeks
          when 4 then next_date.prev_year(frequency)
          else next_date.prev_month(frequency)
          end
        candidate = [ previous_date, Date.current ].min
        start_date = Date.iso8601(subscription["start_date"].to_s)
        [ candidate, start_date ].max
      rescue Date::Error
        candidate
      end

      def truthy?(value)
        value == true || value.to_s == "1"
      end
  end
end

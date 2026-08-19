require "test_helper"

class Wallos::ImporterTest < ActiveSupport::TestCase
  setup do
    @connection = WallosConnection.create!(
      family: families(:dylan_family),
      account: accounts(:credit_card),
      base_url: "https://wallos.example.com",
      api_key: "secret"
    )
    @client = mock
    @client.stubs(:currencies).returns("3" => { "id" => 3, "code" => "CAD" })
  end

  test "imports Wallos fields and paid-by account idempotently" do
    subscription = {
      "id" => 42,
      "name" => "Streaming service",
      "price" => "12.99",
      "currency_id" => 3,
      "start_date" => "2025-01-10",
      "next_payment" => "2026-09-10",
      "inactive" => 0,
      "payer_user_name" => "Jacob",
      "payment_method_name" => "Visa",
      "category_name" => "Entertainment",
      "cycle" => 3,
      "frequency" => 1,
      "auto_renew" => 1
    }
    @client.stubs(:subscriptions).returns([ subscription ])

    2.times { Wallos::Importer.new(@connection, client: @client).import }

    recurring = @connection.family.recurring_transactions.find_by!(source: "wallos", source_id: "42")
    assert_equal accounts(:credit_card), recurring.account
    assert_equal "Streaming service", recurring.name
    assert_equal BigDecimal("12.99"), recurring.amount
    assert_equal "CAD", recurring.currency
    assert_equal Date.new(2026, 9, 10), recurring.next_expected_date
    assert_equal "Jacob", recurring.source_metadata.fetch("payer")
    assert_equal "Visa", recurring.source_metadata.fetch("payment_method")
    assert_equal 1, @connection.family.recurring_transactions.where(source: "wallos", source_id: "42").count
  end

  test "marks subscriptions removed from Wallos inactive" do
    recurring = @connection.family.recurring_transactions.create!(
      account: @connection.account,
      name: "Old subscription",
      amount: 5,
      currency: "CAD",
      expected_day_of_month: 1,
      last_occurrence_date: Date.new(2026, 7, 1),
      next_expected_date: Date.new(2026, 9, 1),
      status: "active",
      occurrence_count: 1,
      manual: true,
      source: "wallos",
      source_id: "old"
    )
    @client.stubs(:subscriptions).returns([])

    Wallos::Importer.new(@connection, client: @client).import

    assert recurring.reload.inactive?
  end

  test "keeps distinct Wallos subscriptions with the same name and price" do
    base_subscription = {
      "name" => "Family streaming",
      "price" => "9.99",
      "currency_id" => 3,
      "start_date" => "2025-01-10",
      "next_payment" => "2026-09-10",
      "inactive" => 0,
      "cycle" => 3,
      "frequency" => 1
    }
    @client.stubs(:subscriptions).returns([
      base_subscription.merge("id" => 101, "payer_user_name" => "Jacob"),
      base_subscription.merge("id" => 102, "payer_user_name" => "Alex")
    ])

    Wallos::Importer.new(@connection, client: @client).import

    assert_equal 2, @connection.family.recurring_transactions.where(source: "wallos", name: "Family streaming").count
  end
end

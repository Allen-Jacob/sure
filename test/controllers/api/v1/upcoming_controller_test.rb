require "test_helper"

class Api::V1::UpcomingControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @series = recurring_transactions(:netflix_subscription)
    @series.recurring_occurrences.delete_all
    @occurrence = @series.recurring_occurrences.create!(family: @series.family,
      original_due_on: Date.current + 20, due_on: Date.current + 20, currency: @series.currency)
    @read_key = make_key("read")
    @write_key = make_key("read_write")
  end

  test "authentication is required" do
    get "/api/v1/upcoming"
    assert_response :unauthorized
  end

  test "includes occurrences beyond the old ten day window and excludes paid ones" do
    get "/api/v1/upcoming", headers: api_headers(@read_key)
    assert_response :success
    assert_includes response.parsed_body.fetch("upcoming").map { |row| row.fetch("id") }, @occurrence.id
    @occurrence.skip!
    get "/api/v1/upcoming", headers: api_headers(@read_key)
    assert_empty response.parsed_body.fetch("upcoming")
  end

  test "rejects invalid dates and inaccessible accounts" do
    get "/api/v1/upcoming", params: { from: "nonsense" }, headers: api_headers(@read_key)
    assert_response :unprocessable_entity
    get "/api/v1/upcoming", params: { from: Date.current.iso8601, to: (Date.current + 400).iso8601 }, headers: api_headers(@read_key)
    assert_response :unprocessable_entity
    get "/api/v1/upcoming", params: { account_id: SecureRandom.uuid }, headers: api_headers(@read_key)
    assert_response :not_found
  end

  test "closed occurrences cannot be edited" do
    @occurrence.skip!
    patch "/api/v1/upcoming/#{@occurrence.id}", params: { expected_amount: "28" }, headers: api_headers(@write_key)
    assert_response :unprocessable_entity
  end

  test "read keys cannot change amounts" do
    patch "/api/v1/upcoming/#{@occurrence.id}", params: { expected_amount: "28" }, headers: api_headers(@read_key)
    assert_response :forbidden
  end

  test "changes one occurrence without changing the recurring amount" do
    original = @series.amount
    patch "/api/v1/upcoming/#{@occurrence.id}", params: { expected_amount: "28.50" }, headers: api_headers(@write_key)
    assert_response :success
    assert_equal BigDecimal("28.50"), @occurrence.reload.expected_amount
    assert_equal original, @series.reload.amount
  end

  test "rejects invalid amounts and unknown occurrences" do
    %w[abc -1 NaN Infinity].each do |amount|
      patch "/api/v1/upcoming/#{@occurrence.id}", params: { expected_amount: amount }, headers: api_headers(@write_key)
      assert_response :unprocessable_entity
    end
    patch "/api/v1/upcoming/#{SecureRandom.uuid}", params: { expected_amount: "28" }, headers: api_headers(@write_key)
    assert_response :not_found
  end

  test "other families cannot read or edit an occurrence" do
    @user = users(:empty)
    key = make_key("read_write")
    get "/api/v1/upcoming", headers: api_headers(key)
    assert_response :success
    assert_empty response.parsed_body.fetch("upcoming")
    patch "/api/v1/upcoming/#{@occurrence.id}", params: { expected_amount: "28" }, headers: api_headers(key)
    assert_response :not_found
  end

  test "paycheck reflects a single occurrence override" do
    @series.update!(merchant: nil, name: "Salary", amount: -1500, bill_type: "income")
    @occurrence.update!(expected_amount: 1625)
    get "/api/v1/paycheck", headers: api_headers(@read_key)
    assert_response :success
    assert_equal BigDecimal("1625"), response.parsed_body.dig("paycheck", "amount", "amount").to_d
  end

  private
    def make_key(scope)
      ApiKey.create!(user: @user, name: "Upcoming #{scope}", scopes: [ scope ],
        display_key: "test_#{SecureRandom.hex(12)}", source: "web")
    end

    def api_headers(key)
      { "X-Api-Key" => key.display_key }
    end
end

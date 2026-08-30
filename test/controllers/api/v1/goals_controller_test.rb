# frozen_string_literal: true

require "test_helper"

class Api::V1::GoalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @user.api_keys.active.destroy_all
    @api_key = ApiKey.create!(
      user: @user,
      name: "Mobile goals",
      scopes: [ "read" ],
      source: "mobile",
      display_key: "test_read_#{SecureRandom.hex(8)}"
    )
    @goal = goals(:vacation_italy)
  end

  test "lists goals from the current family with Sure progress" do
    get api_v1_goals_url, headers: api_headers(@api_key)

    assert_response :success
    payload = JSON.parse(response.body)
    goal = payload.fetch("goals").find { |item| item["id"] == @goal.id }

    assert goal
    assert_equal @goal.name, goal["name"]
    assert_equal @goal.currency, goal["currency"]
    assert_kind_of Integer, goal["target_amount_cents"]
    assert_kind_of Integer, goal["current_amount_cents"]
    assert_kind_of Integer, goal["progress_percent"]
    assert payload.key?("pagination")
  end

  test "shows one goal" do
    get api_v1_goal_url(@goal), headers: api_headers(@api_key)

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal @goal.id, payload["id"]
    assert_equal @goal.display_status.to_s, payload["status"]
  end

  test "does not expose another family's goal" do
    account = families(:empty).accounts.create!(
      owner: users(:empty),
      name: "Private savings",
      balance: 0,
      currency: "USD",
      accountable: Depository.create!,
      status: "active"
    )
    other_goal = families(:empty).goals.new(
      name: "Private goal",
      target_amount: 1000,
      currency: "USD"
    )
    other_goal.goal_accounts.build(account: account)
    other_goal.save!

    get api_v1_goal_url(other_goal), headers: api_headers(@api_key)

    assert_response :not_found
  end

  test "requires authentication and read scope" do
    get api_v1_goals_url
    assert_response :unauthorized

    no_scope_key = ApiKey.new(
      user: @user,
      name: "No read",
      scopes: [],
      source: "mobile",
      display_key: "no_read_#{SecureRandom.hex(8)}"
    )
    no_scope_key.save!(validate: false)

    get api_v1_goals_url, headers: api_headers(no_scope_key)
    assert_response :forbidden
  ensure
    no_scope_key&.destroy
  end
end

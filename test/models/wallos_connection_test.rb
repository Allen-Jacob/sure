require "test_helper"

class WallosConnectionTest < ActiveSupport::TestCase
  test "normalizes a valid self-hosted URL" do
    connection = WallosConnection.new(
      family: families(:dylan_family),
      account: accounts(:depository),
      base_url: " http://wallos.local:8282/ ",
      api_key: "secret"
    )

    assert connection.valid?
    assert_equal "http://wallos.local:8282", connection.base_url
  end

  test "rejects credentials embedded in the URL" do
    connection = WallosConnection.new(
      family: families(:dylan_family),
      account: accounts(:depository),
      base_url: "https://user:password@wallos.example.com",
      api_key: "secret"
    )

    assert_not connection.valid?
    assert connection.errors.added?(:base_url, :invalid)
  end

  test "rejects an account from another family" do
    connection = WallosConnection.new(
      family: families(:empty),
      account: accounts(:depository),
      base_url: "https://wallos.example.com",
      api_key: "secret"
    )

    assert_not connection.valid?
    assert connection.errors.added?(:account, :invalid)
  end
end

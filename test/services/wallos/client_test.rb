require "test_helper"

class Wallos::ClientTest < ActiveSupport::TestCase
  setup do
    @client = Wallos::Client.new(base_url: "https://wallos.example.com", api_key: "secret key")
  end

  test "loads subscriptions using the Wallos API key" do
    request = stub_request(:post, "https://wallos.example.com/api/subscriptions/get_subscriptions.php")
      .with(body: { api_key: "secret key" })
      .to_return(status: 200, body: { success: true, subscriptions: [ { id: 42 } ] }.to_json)

    assert_equal [ { "id" => 42 } ], @client.subscriptions
    assert_requested request
  end

  test "raises a safe error when Wallos rejects the key" do
    stub_request(:post, /wallos\.example\.com/)
      .to_return(status: 200, body: { success: false, title: "Invalid API key" }.to_json)

    error = assert_raises(Wallos::Client::Error) { @client.subscriptions }
    assert_equal "Invalid API key", error.message
  end

  test "indexes currencies by Wallos id" do
    stub_request(:post, "https://wallos.example.com/api/currencies/get_currencies.php")
      .with(body: { api_key: "secret key" })
      .to_return(status: 200, body: { success: true, currencies: [ { id: 3, code: "CAD" } ] }.to_json)

    assert_equal "CAD", @client.currencies.fetch("3").fetch("code")
  end
end

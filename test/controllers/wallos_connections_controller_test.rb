require "test_helper"

class WallosConnectionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
  end

  test "creates a connection and imports subscriptions" do
    Wallos::Importer.any_instance.stubs(:import).returns(Wallos::Importer::Result.new(imported_count: 2, inactive_count: 0))

    assert_difference "WallosConnection.count", 1 do
      post wallos_connection_url, params: {
        wallos_connection: {
          base_url: "https://wallos.example.com",
          api_key: "secret",
          account_id: accounts(:credit_card).id
        }
      }
    end

    assert_redirected_to recurring_transactions_path
    assert_equal accounts(:credit_card), families(:dylan_family).wallos_connection.account
  end

  test "updates paid-by account without clearing the API key" do
    connection = WallosConnection.create!(
      family: families(:dylan_family),
      account: accounts(:credit_card),
      base_url: "https://wallos.example.com",
      api_key: "secret"
    )

    patch wallos_connection_url, params: {
      wallos_connection: {
        base_url: connection.base_url,
        api_key: "",
        account_id: accounts(:depository).id
      }
    }

    assert_redirected_to recurring_transactions_path
    assert_equal "secret", connection.reload.api_key
    assert_equal accounts(:depository), connection.account
  end

  test "does not allow a non-admin to connect Wallos" do
    sign_in users(:family_member)

    assert_no_difference "WallosConnection.count" do
      post wallos_connection_url, params: {
        wallos_connection: {
          base_url: "https://wallos.example.com",
          api_key: "secret",
          account_id: accounts(:depository).id
        }
      }
    end

    assert_redirected_to accounts_path
  end
end

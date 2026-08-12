# frozen_string_literal: true

require "swagger_helper"

RSpec.describe "API V1 Goals", type: :request do
  let(:family) do
    Family.create!(
      name: "API Family",
      currency: "USD",
      locale: "en",
      date_format: "%m-%d-%Y"
    )
  end
  let(:user) do
    family.users.create!(
      email: "goals-api@example.com",
      password: "password123",
      password_confirmation: "password123"
    )
  end
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: "API Docs Key",
      key: key,
      display_key: key,
      scopes: %w[read],
      source: "web"
    )
  end
  let(:api_key_without_read_scope) do
    key = ApiKey.generate_secure_key
    ApiKey.new(
      user: user,
      name: "No Read",
      key: key,
      display_key: key,
      scopes: [],
      source: "mobile"
    ).tap { |record| record.save!(validate: false) }
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let!(:account) do
    family.accounts.create!(
      name: "Savings",
      balance: 500,
      currency: "USD",
      accountable: Depository.create!
    )
  end
  let!(:goal) do
    family.goals.new(name: "Trip", target_amount: 2000, currency: "USD").tap do |record|
      record.goal_accounts.build(account: account)
      record.save!
    end
  end

  path "/api/v1/goals" do
    get "List goals" do
      tags "Goals"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      parameter name: :page, in: :query, type: :integer, required: false
      parameter name: :per_page, in: :query, type: :integer, required: false

      response "200", "goals listed" do
        schema '$ref' => '#/components/schemas/GoalCollection'
        run_test!
      end

      response "401", "unauthorized" do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { nil }
        run_test!
      end

      response "403", "insufficient scope" do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { api_key_without_read_scope.plain_key }
        run_test!
      end
    end
  end

  path "/api/v1/goals/{id}" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }

    get "Retrieve a goal" do
      tags "Goals"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      let(:id) { goal.id }

      response "200", "goal retrieved" do
        schema '$ref' => '#/components/schemas/Goal'
        run_test!
      end

      response "404", "goal not found" do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:id) { SecureRandom.uuid }
        run_test!
      end
    end
  end
end

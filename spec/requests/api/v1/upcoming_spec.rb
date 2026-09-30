require 'swagger_helper'

RSpec.describe 'API V1 Upcoming', type: :request do
  let(:family) { Family.create!(name: 'Upcoming API', currency: 'CAD') }
  let(:user) { family.users.create!(email: 'upcoming@example.com', password: 'password123', password_confirmation: 'password123') }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: 'API Docs Key', key: key, scopes: %w[read_write], source: 'web')
  end
  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/upcoming' do
    get 'List scheduled transactions' do
      tags 'Upcoming'
      description 'Open occurrences, ordered by effective due date. Defaults to the next 90 days; maximum range is 366 days. Use GET /api/v1/paycheck for the next predicted paycheck. Amounts are absolute and retain their own currencies.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :from, in: :query, required: false, schema: { type: :string, format: :date }
      parameter name: :to, in: :query, required: false, schema: { type: :string, format: :date }
      parameter name: :account_id, in: :query, required: false, schema: { type: :string, format: :uuid }
      response '200', 'scheduled transactions' do
        schema '$ref' => '#/components/schemas/UpcomingResponse'
        run_test!
      end
      response '401', 'unauthorized' do
        let(:'X-Api-Key') { 'invalid-key' }
        run_test!
      end
      response '422', 'invalid date range' do
        let(:from) { 'invalid' }
        run_test!
      end
      response '404', 'account not accessible' do
        let(:account_id) { SecureRandom.uuid }
        run_test!
      end
    end
  end

  path '/api/v1/upcoming/{id}' do
    patch 'Adjust the expected amount for one scheduled occurrence' do
      tags 'Upcoming'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      consumes 'application/json'
      parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, required: %w[expected_amount],
        properties: { expected_amount: { type: :string, example: '1500.25' } }
      }
      let(:series) do
        family.recurring_transactions.create!(name: 'Paycheck', amount: -1500, currency: 'CAD',
          bill_type: 'income', expected_day_of_month: 15, next_expected_date: Date.current + 10, status: 'active')
      end
      let(:id) { series.recurring_occurrences.scheduled.first!.id }
      let(:body) { { expected_amount: '1500.25' } }
      response '200', 'amount adjusted' do
        schema '$ref' => '#/components/schemas/UpcomingOccurrence'
        run_test!
      end
      response '401', 'unauthorized' do
        let(:'X-Api-Key') { 'invalid-key' }
        run_test!
      end
      response '403', 'read-only key' do
        before { api_key.update!(scopes: %w[read]) }
        run_test!
      end
      response '404', 'occurrence not accessible' do
        let(:id) { SecureRandom.uuid }
        run_test!
      end
      response '422', 'invalid amount' do
        let(:body) { { expected_amount: '-1' } }
        run_test!
      end
    end
  end
end

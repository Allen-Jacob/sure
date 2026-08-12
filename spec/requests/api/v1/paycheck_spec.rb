# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Paycheck', type: :request do
  let(:family) do
    Family.create!(
      name: 'API Paycheck Family',
      currency: 'CAD',
      locale: 'en',
      date_format: '%Y-%m-%d'
    )
  end

  let(:user) do
    family.users.create!(
      email: 'api-paycheck@example.com',
      password: 'password123',
      password_confirmation: 'password123'
    )
  end

  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user,
      name: 'API Docs Paycheck Key',
      key: key,
      scopes: %w[read],
      source: 'web'
    )
  end

  let(:'X-Api-Key') { api_key.plain_key }

  path '/api/v1/paycheck' do
    get 'Show upcoming paycheck' do
      tags 'Paycheck'
      description 'Returns the upcoming paycheck calculated by Sure, including Agendrix-based estimates when configured. Calendar URLs and payroll settings are never exposed.'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'

      response '200', 'paycheck returned' do
        schema '$ref' => '#/components/schemas/PaycheckResponse'

        run_test!
      end

      response '401', 'unauthorized' do
        schema '$ref' => '#/components/schemas/ErrorResponse'
        let(:'X-Api-Key') { 'invalid-key' }

        run_test!
      end
    end
  end
end

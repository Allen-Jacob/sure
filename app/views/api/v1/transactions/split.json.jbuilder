# frozen_string_literal: true

json.transactions @transactions do |transaction|
  json.partial! "api/v1/transactions/transaction", transaction: transaction
end

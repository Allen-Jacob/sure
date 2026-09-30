require "test_helper"

class RecurringTransaction::UpcomingTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @series = recurring_transactions(:netflix_subscription)
    @series.recurring_occurrences.delete_all
  end

  test "uses snoozed dates and orders the next three occurrences for an account" do
    dates = [ 30, 5, 12, 20 ].map { |days| Date.current + days }
    rows = dates.map do |date|
      @series.recurring_occurrences.create!(family: @series.family, original_due_on: date, due_on: date, currency: "USD")
    end
    rows[1].update!(snoozed_until: Date.current + 40)
    result = RecurringTransaction::Upcoming.new(user: @user, account: @series.account).occurrences.limit(3)
    assert_equal [ rows[2].id, rows[3].id, rows[0].id ], result.map(&:id)
    assert_empty RecurringTransaction::Upcoming.new(user: @user, account: accounts(:credit_card)).occurrences
  end

  test "excludes inactive series and settled occurrences" do
    row = @series.recurring_occurrences.create!(family: @series.family,
      original_due_on: Date.current, due_on: Date.current, currency: "USD")
    row.skip!
    assert_empty RecurringTransaction::Upcoming.new(user: @user).occurrences
    row.reopen!
    @series.update!(status: :inactive)
    assert_empty RecurringTransaction::Upcoming.new(user: @user).occurrences
  end
end

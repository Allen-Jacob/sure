require "test_helper"

class UpcomingViewsTest < ActionDispatch::IntegrationTest
  setup do
    sign_in @user = users(:family_admin)
    @user.update!(preferences: (@user.preferences || {}).merge("preview_features_enabled" => true))
    @series = recurring_transactions(:netflix_subscription)
    @series.recurring_occurrences.delete_all
    @occurrences = [ 2, 14, 30, 45 ].map do |days|
      date = Date.current + days
      @series.recurring_occurrences.create!(family: @series.family,
        original_due_on: date, due_on: date, currency: "USD")
    end
    ensure_tailwind_build
  end

  test "upcoming tab links to editable occurrences beyond ten days" do
    get transactions_url(tab: "upcoming")
    assert_response :success
    @occurrences.each do |occurrence|
      assert_select "a[href='#{recurring_occurrence_path(occurrence)}'][data-turbo-frame='modal']"
    end
    assert_select "h2", text: I18n.t("upcoming.next_paycheck")
  end

  test "account disclosure contains only the next three occurrences" do
    get account_url(@series.account)
    assert_response :success
    @occurrences.first(3).each do |occurrence|
      assert_select "details a[href='#{recurring_occurrence_path(occurrence)}']"
    end
    assert_select "a[href='#{recurring_occurrence_path(@occurrences.last)}']", count: 0
    assert_select "a[href='#{new_recurring_transaction_path(account_id: @series.account_id)}']"
  end
end

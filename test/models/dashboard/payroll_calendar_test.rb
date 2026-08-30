require "test_helper"

class Dashboard::PayrollCalendarTest < ActiveSupport::TestCase
  CALENDAR_URL = "https://app.agendrix.com/api/calendar/11111111-2222-3333-4444-555555555555.ics"

  setup do
    Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
  end

  test "accepts only public Agendrix calendar URLs" do
    assert Dashboard::PayrollCalendar.valid_url?(CALENDAR_URL)

    assert_not Dashboard::PayrollCalendar.valid_url?("http://app.agendrix.com/api/calendar/11111111-2222-3333-4444-555555555555.ics")
    assert_not Dashboard::PayrollCalendar.valid_url?("https://localhost/api/calendar/11111111-2222-3333-4444-555555555555.ics")
    assert_not Dashboard::PayrollCalendar.valid_url?("https://app.agendrix.com.example.com/api/calendar/11111111-2222-3333-4444-555555555555.ics")
    assert_not Dashboard::PayrollCalendar.valid_url?("https://app.agendrix.com/api/calendar/not-a-calendar.ics")
    assert_not Dashboard::PayrollCalendar.valid_url?("https://app.agendrix.com/api/calendar/11111111-2222-3333-4444-555555555555.ics?redirect=http://localhost")
  end

  test "totals timed shifts in the requested pay period and caches the calendar" do
    request = stub_request(:get, CALENDAR_URL).to_return(
      status: 200,
      headers: { "Content-Type" => "text/calendar" },
      body: <<~ICS.gsub("\n", "\r\n")
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        UID:first-shift
        DTSTART;TZID=America/New_York:20260815T083000
        DTEND;TZID=America/New_York:20260815T170000
        SUMMARY:Scheduled shift
        END:VEVENT
        BEGIN:VEVENT
        UID:second-shift
        DTSTART:20260810T130000Z
        DTEND:20260810T170000Z
        END:VEVENT
        BEGIN:VEVENT
        UID:second-shift
        DTSTART:20260810T130000Z
        DTEND:20260810T170000Z
        END:VEVENT
        BEGIN:VEVENT
        UID:outside-period
        DTSTART;TZID=America/New_York:20260816T090000
        DTEND;TZID=America/New_York:20260816T180000
        END:VEVENT
        BEGIN:VEVENT
        UID:cancelled-shift
        DTSTART;TZID=America/New_York:20260812T090000
        DTEND;TZID=America/New_York:20260812T170000
        STATUS:CANCELLED
        END:VEVENT
        BEGIN:VEVENT
        UID:all-day-note
        DTSTART;VALUE=DATE:20260812
        DTEND;VALUE=DATE:20260813
        END:VEVENT
        END:VCALENDAR
      ICS
    )

    calendar = Dashboard::PayrollCalendar.new(url: CALENDAR_URL)

    assert_equal 12.5.to_d, calendar.hours_between(Date.new(2026, 8, 2), Date.new(2026, 8, 15))
    assert_equal 12.5.to_d, calendar.hours_between(Date.new(2026, 8, 2), Date.new(2026, 8, 15))
    assert_requested request, times: 1
  end

  test "raises an unavailable error when Agendrix cannot be reached" do
    stub_request(:get, CALENDAR_URL).to_return(status: 503, body: "Unavailable")

    assert_raises Dashboard::PayrollCalendar::Unavailable do
      Dashboard::PayrollCalendar.new(url: CALENDAR_URL).hours_between(Date.new(2026, 8, 2), Date.new(2026, 8, 15))
    end
  end
end

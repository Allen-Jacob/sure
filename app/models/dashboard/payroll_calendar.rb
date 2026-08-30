require "digest"
require "time"
require "uri"

module Dashboard
  class PayrollCalendar
    ALLOWED_HOST = "app.agendrix.com"
    CALENDAR_PATH = %r{\A/api/calendar/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.ics\z}i
    CACHE_TTL = 15.minutes
    MAX_RESPONSE_BYTES = 1.megabyte

    class Error < StandardError; end
    class InvalidUrl < Error; end
    class Unavailable < Error; end

    Event = Struct.new(:uid, :starts_at, :ends_at, keyword_init: true) do
      def date
        starts_at.to_date
      end

      def hours
        (ends_at - starts_at).to_i.to_d / 1.hour.to_i
      end
    end

    def self.valid_url?(value)
      uri = URI.parse(value.to_s.strip)

      uri.scheme == "https" &&
        uri.host == ALLOWED_HOST &&
        uri.port == 443 &&
        uri.userinfo.nil? &&
        uri.query.nil? &&
        uri.fragment.nil? &&
        uri.path.match?(CALENDAR_PATH)
    rescue URI::InvalidURIError
      false
    end

    def initialize(url:)
      @url = url.to_s.strip
      raise InvalidUrl unless self.class.valid_url?(@url)
    end

    def hours_between(start_date, end_date)
      events.sum(0.to_d) do |event|
        event.date.in?(start_date..end_date) ? event.hours : 0.to_d
      end
    end

    private
      def events
        Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
          parse(fetch_calendar)
        end
      rescue Faraday::Error => error
        raise Unavailable, error.message
      end

      def cache_key
        [ "dashboard", "payroll_calendar", Digest::SHA256.hexdigest(@url) ]
      end

      def fetch_calendar
        response = Faraday.get(@url) do |request|
          request.headers["Accept"] = "text/calendar"
          request.options.open_timeout = 3
          request.options.timeout = 5
        end
        raise Unavailable, "Calendar returned HTTP #{response.status}" unless response.success?

        body = response.body.to_s
        raise Unavailable, "Calendar response is too large" if body.bytesize > MAX_RESPONSE_BYTES

        body
      end

      def parse(body)
        unfolded_lines = body.gsub(/\r?\n[ \t]/, "").split(/\r?\n/)
        raw_events = []
        current_event = nil

        unfolded_lines.each do |line|
          case line
          when "BEGIN:VEVENT"
            current_event = {}
          when "END:VEVENT"
            raw_events << current_event if current_event
            current_event = nil
          else
            next unless current_event

            property, value = line.split(":", 2)
            next unless value

            name, *parameters = property.split(";")
            current_event[name] = { value: value, parameters: parameters }
          end
        end

        raw_events.filter_map { |attributes| build_event(attributes) }
                  .uniq { |event| event.uid.presence || [ event.starts_at, event.ends_at ] }
      end

      def build_event(attributes)
        return if attributes.dig("STATUS", :value)&.casecmp?("CANCELLED")

        starts_at = parse_datetime(attributes["DTSTART"])
        ends_at = parse_datetime(attributes["DTEND"])
        return unless starts_at && ends_at && ends_at > starts_at

        Event.new(
          uid: attributes.dig("UID", :value),
          starts_at: starts_at,
          ends_at: ends_at
        )
      rescue ArgumentError, TZInfo::InvalidTimezoneIdentifier
        nil
      end

      def parse_datetime(property)
        return unless property

        value = property.fetch(:value)
        parameters = property.fetch(:parameters)
        return if value.match?(/\A\d{8}\z/) || parameters.include?("VALUE=DATE")

        format = value.match?(/\A\d{8}T\d{4}Z?\z/) ? "%Y%m%dT%H%M" : "%Y%m%dT%H%M%S"
        return Time.strptime(value, "#{format}Z").utc if value.end_with?("Z")

        timezone_id = parameters.find { |parameter| parameter.start_with?("TZID=") }&.delete_prefix("TZID=")&.delete('"')
        timezone = timezone_id.present? ? ActiveSupport::TimeZone[timezone_id] : Time.zone
        raise ArgumentError, "Unknown calendar timezone" unless timezone

        timezone.strptime(value, format)
      end
  end
end

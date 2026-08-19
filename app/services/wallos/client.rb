require "net/http"

module Wallos
  class Client
    class Error < StandardError; end

    def initialize(base_url:, api_key:)
      @base_uri = URI.parse(base_url)
      @api_key = api_key
    end

    def subscriptions
      request_json("api/subscriptions/get_subscriptions.php").fetch("subscriptions")
    rescue KeyError
      raise Error, "Wallos returned an incomplete response"
    end

    def currencies
      response = request_json("api/currencies/get_currencies.php")
      response.fetch("currencies").index_by { |currency| currency.fetch("id").to_s }
    rescue KeyError
      raise Error, "Wallos returned an incomplete response"
    end

    private

      def request_json(path)
        uri = @base_uri.dup
        uri.path = [ @base_uri.path.to_s.sub(%r{/+\z}, ""), path ].reject(&:blank?).join("/")
        uri.path = "/#{uri.path}" unless uri.path.start_with?("/")
        request = Net::HTTP::Post.new(uri)
        request["Accept"] = "application/json"
        request.set_form_data(api_key: @api_key)

        response = Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == "https",
          open_timeout: 5,
          read_timeout: 15
        ) { |http| http.request(request) }

        raise Error, "Wallos returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        payload = JSON.parse(response.body)
        raise Error, payload["title"].presence || "Wallos rejected the request" unless payload["success"] == true

        payload
      rescue JSON::ParserError
        raise Error, "Wallos returned an invalid JSON response"
      rescue SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => error
        raise Error, "Unable to reach Wallos: #{error.message}"
      end
  end
end

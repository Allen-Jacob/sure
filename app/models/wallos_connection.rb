class WallosConnection < ApplicationRecord
  include Encryptable

  belongs_to :family
  belongs_to :account

  if encryption_ready?
    encrypts :api_key
  end

  validates :base_url, :api_key, presence: true
  validate :base_url_is_http
  validate :account_belongs_to_family

  before_validation :normalize_base_url

  def sync!
    Wallos::Importer.new(self).import
  end

  private

    def normalize_base_url
      self.base_url = base_url.to_s.strip.sub(%r{/+\z}, "")
    end

    def base_url_is_http
      uri = URI.parse(base_url.to_s)
      return if uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank? && uri.query.blank? && uri.fragment.blank?

      errors.add(:base_url, :invalid)
    rescue URI::InvalidURIError
      errors.add(:base_url, :invalid)
    end

    def account_belongs_to_family
      return if account.blank? || family.blank? || account.family_id == family_id

      errors.add(:account, :invalid)
    end
end

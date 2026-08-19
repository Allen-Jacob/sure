class WallosConnectionsController < ApplicationController
  before_action :require_admin!
  before_action :set_connection, only: [ :update, :destroy, :sync ]

  def create
    @connection = Current.family.build_wallos_connection(connection_params)
    @connection.save!
    result = @connection.sync!
    redirect_to recurring_transactions_path, notice: t("recurring_transactions.wallos.connected", count: result.imported_count)
  rescue ActiveRecord::RecordInvalid, Wallos::Client::Error => error
    capture_sync_error(error, action: "create")
    @connection&.destroy if @connection&.persisted? && @connection.last_synced_at.nil?
    redirect_to recurring_transactions_path, alert: error.message
  end

  def update
    attributes = connection_params
    attributes.delete(:api_key) if attributes[:api_key].blank?
    @connection.update!(attributes)
    redirect_to recurring_transactions_path, notice: t("recurring_transactions.wallos.settings_updated")
  rescue ActiveRecord::RecordInvalid => error
    redirect_to recurring_transactions_path, alert: error.message
  end

  def sync
    result = @connection.sync!
    redirect_to recurring_transactions_path, notice: t("recurring_transactions.wallos.synced", count: result.imported_count)
  rescue Wallos::Client::Error, ActiveRecord::RecordInvalid => error
    capture_sync_error(error, action: "sync")
    redirect_to recurring_transactions_path, alert: error.message
  end

  def destroy
    @connection.destroy!
    redirect_to recurring_transactions_path, notice: t("recurring_transactions.wallos.disconnected")
  end

  private

    def set_connection
      @connection = Current.family.wallos_connection
      redirect_to(recurring_transactions_path, alert: t("recurring_transactions.wallos.not_connected")) unless @connection
    end

    def connection_params
      params.require(:wallos_connection).permit(:base_url, :api_key, :account_id)
    end

    def capture_sync_error(error, action:)
      DebugLogEntry.capture(
        category: "provider_sync",
        level: "error",
        message: error.message,
        source: "WallosConnectionsController##{action}",
        provider_key: "wallos",
        family: Current.family,
        metadata: { connection_id: @connection&.id }
      )
    end
end

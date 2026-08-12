# frozen_string_literal: true

class Api::V1::GoalsController < Api::V1::BaseController
  include Pagy::Backend

  before_action :ensure_read_scope
  before_action :set_goal, only: :show

  def index
    @per_page = safe_per_page_param
    @pagy, @goals = pagy(
      goals_scope,
      page: safe_page_param,
      limit: @per_page
    )
    Goal.inject_backing_math!(@goals, current_resource_owner.family)

    render :index
  end

  def show
    Goal.inject_backing_math!([ @goal ], current_resource_owner.family)
    render :show
  end

  private

    def ensure_read_scope
      authorize_scope!(:read)
    end

    def set_goal
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])

      @goal = goals_scope.find(params[:id])
    end

    def goals_scope
      current_resource_owner.family.goals
                            .includes(:open_pledges, :goal_accounts, linked_accounts: :account_providers)
                            .active_first
                            .alphabetically
    end
end

class Api::V1::MembershipsController < Api::ApiController
  before_filter :require_login
  require_authentication :all, scopes: [:group]
  resource_actions :index, :show, :create, :update, :deactivate
  schema_type :strong_params

  allowed_params :create, :join_token, links: [:user, :user_group]
  allowed_params :update, :state

  def create
    resources = resource_class.transaction(requires_new: true) do

      Array.wrap(create_params).map do |membership_params|
        Memberships::Create.run!(membership_params.merge(api_user: api_user))
      end
    end

    created_resource_response(resources)
  end


  private

  def add_active_resources_scope
    false
  end
end

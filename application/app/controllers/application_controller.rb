class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :set_current_tenant

  def current_user
    @current_user ||= User.find(session[:user_id]) if session[:user_id]
  end
  helper_method :current_user

  private

  def set_current_tenant
    @current_tenant = Tenant.find_by(subdomain: request.subdomain)
  end
  helper_method :current_tenant

  def current_tenant
    @current_tenant
  end
end

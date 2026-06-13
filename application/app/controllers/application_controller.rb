class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :set_current_tenant

  def current_user
    @current_user ||= User.find(session[:user_id]) if session[:user_id]
  end
  helper_method :current_user

  def current_tenant
    Current.tenant
  end
  helper_method :current_tenant

  private

  # subdomain でテナントを解決し、Current.tenant に置く。
  # マッチしない場合は "default" tenant を fallback として使う（dev/test 用）。
  # 本番では subdomain 必須として 404 を返す等、別途運用方針が必要。
  def set_current_tenant
    Current.tenant = Tenant.find_by(subdomain: request.subdomain.presence) ||
                     Tenant.find_by(subdomain: "default")
  end
end

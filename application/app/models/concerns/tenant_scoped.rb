module TenantScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :tenant, optional: true

    before_validation :assign_tenant_id_from_current
    validate :tenant_must_match_current

    scope :for_current_tenant, -> {
      Current.tenant ? where(tenant_id: Current.tenant.id) : all
    }
  end

  private

  def assign_tenant_id_from_current
    self.tenant_id ||= Current.tenant&.id
  end

  # Current.tenant が設定されている場合、tenant_id が別テナントを指していたら拒否する。
  # NULLABLE 期間中は tenant_id が nil の既存行を許容する（バックフィルで埋める想定）。
  def tenant_must_match_current
    return if Current.tenant.nil?
    return if tenant_id.nil?
    return if tenant_id == Current.tenant.id

    errors.add(:tenant_id, "他テナントの参照は禁止")
  end
end

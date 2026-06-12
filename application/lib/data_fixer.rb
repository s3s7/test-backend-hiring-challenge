# frozen_string_literal: true

# 既存データの修復・正規化を冪等に行う。
#
# rake task `app:fix_data` と、整合性制約を付与する migration の両方から呼ばれる
# 単一ソース。各ステップは WHERE 句で対象を絞り、対象 0 件なら no-op になるため
# 何度実行しても安全。
#
# 注意: 「修復」の中には destroy/delete を含む不可逆操作がある。migration の down では
# 制約のみ巻き戻し、データは復元しない。詳細は notes/3-validation.md。
class DataFixer
  def self.run!(logger: Rails.logger)
    new(logger: logger).run!
  end

  def initialize(logger: Rails.logger)
    @logger = logger
  end

  def run!
    normalize_user_emails
    consolidate_duplicate_users
    purge_invalid_users
    purge_invalid_posts
    purge_invalid_comments
    dedup_tenant_subdomains
    purge_invalid_tenants
  end

  private

  attr_reader :logger

  def log(msg)
    logger&.info("[DataFixer] #{msg}")
  end

  # email を小文字に正規化。1 本 SQL で済むためループ不要。
  # WHERE で「未正規化のみ」を対象にし、2回目以降は 0 件。
  #
  # 注意: column collation が utf8mb4_0900_ai_ci のため、素の `<>` 比較は
  # 大小無視で常に等しいと判定される。BINARY 比較に落とすことで
  # 「バイト列として違う」= 大文字が混じっている行だけを対象にする。
  def normalize_user_emails
    updated = User
      .where("email IS NOT NULL AND BINARY email <> LOWER(email)")
      .update_all("email = LOWER(email), updated_at = NOW()")
    log("normalize_user_emails: #{updated} rows lowercased") if updated.positive?
  end

  # 大小無視で同一 email を持つ複数 user を 1 行に統合する。
  #
  # survivor の選び方: 「valid な行（name/password が空でない）」を優先し、
  # 同条件内で created_at ASC → id ASC。理由: 直後の purge_invalid_users で
  # invalid な survivor が即削除されると「統合した意味が消える」ため。
  #
  # 順序: (1) 関連 posts/comments の user_id を残存 user に付け替え
  #     → (2) 重複 user を delete。逆順だと孤児レコードが残る。
  def consolidate_duplicate_users
    canonical_emails = User
      .where.not(email: [ nil, "" ])
      .group("LOWER(email)")
      .having("COUNT(*) > 1")
      .pluck(Arel.sql("LOWER(email)"))
    return if canonical_emails.empty?

    canonical_emails.each do |canonical|
      group = User.where("LOWER(email) = ?", canonical).order(:created_at, :id).to_a
      survivor = group.find { |u| u.name.present? && u.password.present? } || group.first
      duplicate_ids = group.reject { |u| u.id == survivor.id }.map(&:id)
      next if duplicate_ids.empty?

      now = Time.current
      Post.where(user_id: duplicate_ids).update_all(user_id: survivor.id, updated_at: now)
      Comment.where(user_id: duplicate_ids).update_all(user_id: survivor.id, updated_at: now)
      User.where(id: duplicate_ids).delete_all
    end
    log("consolidate_duplicate_users: merged #{canonical_emails.size} groups")
  end

  # name/email/password のいずれかが NULL or 空文字の user を、関連ごと排除。
  # posts は NOT NULL FK のため delete cascade、comments は user_id を NULL に。
  def purge_invalid_users
    invalid_ids = User.where(
      "name IS NULL OR name = '' OR email IS NULL OR email = '' OR password IS NULL OR password = ''"
    ).pluck(:id)
    return if invalid_ids.empty?

    now = Time.current
    Post.where(user_id: invalid_ids).delete_all
    Comment.where(user_id: invalid_ids).update_all(user_id: nil, updated_at: now)
    User.where(id: invalid_ids).delete_all
    log("purge_invalid_users: #{invalid_ids.size} rows purged")
  end

  def purge_invalid_posts
    invalid_ids = Post.where(
      "title IS NULL OR title = '' OR content IS NULL OR content = ''"
    ).pluck(:id)
    return if invalid_ids.empty?

    Comment.where(post_id: invalid_ids).delete_all
    Post.where(id: invalid_ids).delete_all
    log("purge_invalid_posts: #{invalid_ids.size} rows purged")
  end

  def purge_invalid_comments
    deleted = Comment.where(
      "content IS NULL OR content = '' OR name IS NULL OR name = ''"
    ).delete_all
    log("purge_invalid_comments: #{deleted} rows purged") if deleted.positive?
  end

  # subdomain は column collation utf8mb4_0900_ai_ci で比較が元から大小無視。
  # 同一 subdomain の重複から最古を残す。
  def dedup_tenant_subdomains
    subdomains = Tenant
      .where.not(subdomain: [ nil, "" ])
      .group(:subdomain)
      .having("COUNT(*) > 1")
      .pluck(:subdomain)
    return if subdomains.empty?

    subdomains.each do |subdomain|
      group = Tenant.where(subdomain: subdomain).order(:created_at, :id).to_a
      Tenant.where(id: group.drop(1).map(&:id)).delete_all
    end
    log("dedup_tenant_subdomains: deduped #{subdomains.size} groups")
  end

  def purge_invalid_tenants
    deleted = Tenant.where(
      "name IS NULL OR name = '' OR subdomain IS NULL OR subdomain = ''"
    ).delete_all
    log("purge_invalid_tenants: #{deleted} rows purged") if deleted.positive?
  end
end

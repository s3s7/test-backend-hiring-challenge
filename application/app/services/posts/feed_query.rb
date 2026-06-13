# frozen_string_literal: true

module Posts
  # PostsController#feed の業務ロジック。
  # 一覧の取得（eager load 含む）と JSON ボディ用ハッシュへの整形までを担う。
  # 文字列正規化（normalize）も feed 固有の責務としてこのサービス内に閉じる。
  class FeedQuery
    DEFAULT_LIMIT = 100

    # 第9問: 低レイヤキャッシュの TTL と race_condition_ttl。
    # TTL は「Post の touch/INSERT/DELETE が失われた時の最大 staleness 上限」。
    # race_condition_ttl は「キャッシュ期限直後に複数リクエストが同時に再計算しに
    # 行くサンダリングハード防止」。期限切れの瞬間、1 プロセスだけ再計算する間、
    # 他のプロセスは古い値を最大 race_condition_ttl 秒返す。
    CACHE_TTL = 5.minutes
    CACHE_RACE_TTL = 30.seconds

    def initialize(scope: Post.all, limit: DEFAULT_LIMIT)
      @scope = scope
      @limit = limit
    end

    def call
      posts.map { |post| serialize(post) }
    end

    # PostsController#feed から呼ばれる入口。
    # 低レイヤキャッシュ層は controller ではなくサービスに置いた。理由は
    # 「キャッシュキーの構築には scope を知る必要があるので、scope を持っている
    # 側に閉じる方が controller がキャッシュの存在を意識しなくて済む」ため。
    def cached_call
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL, race_condition_ttl: CACHE_RACE_TTL) do
        call
      end
    end

    private

    attr_reader :scope, :limit

    def posts
      scope.includes(:user, :comments).limit(limit)
    end

    def serialize(post)
      {
        id: post.id,
        title: normalize(post.title),
        author: post.user&.name,
        body: normalize(post.content),
        comment_count: post.comments.size
      }
    end

    def normalize(text)
      text.to_s.gsub(/\s+/, " ").strip
    end

    # cache_key_with_version は scope の max(updated_at) と count を 1 クエリで
    # 集約し、結果をキー化する Rails 5.2+ の機能。Post の INSERT/UPDATE/DELETE
    # が起きた時点で集約値が変わり、新しいキャッシュキーになる（= 古いキャッシュは
    # 「expire」されずに参照されなくなる = race 無しの自然失効）。
    # Comment 側は belongs_to :post, touch: true で Post.updated_at を bump する
    # 経路に乗せている（comment_count 変化を feed に反映するため）。
    # tenant プレフィックスを噛ませてマルチテナント間でキャッシュバケットを分離。
    def cache_key
      tenant_id = Current.tenant&.id || "global"
      [ "posts/feed", "tenant=#{tenant_id}", "limit=#{limit}", scope.cache_key_with_version ]
    end
  end
end

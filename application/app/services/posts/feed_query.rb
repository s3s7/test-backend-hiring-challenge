# frozen_string_literal: true

module Posts
  # PostsController#feed の業務ロジック。
  # 一覧の取得（eager load 含む）と JSON ボディ用ハッシュへの整形までを担う。
  # 文字列正規化（normalize）も feed 固有の責務としてこのサービス内に閉じる。
  class FeedQuery
    DEFAULT_LIMIT = 100

    def initialize(scope: Post.all, limit: DEFAULT_LIMIT)
      @scope = scope
      @limit = limit
    end

    def call
      posts.map { |post| serialize(post) }
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
  end
end

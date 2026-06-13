# frozen_string_literal: true

module Posts
  # PostsController#export の業務ロジック。
  # eager load 込みの全件取得と CSV 文字列の生成までを担う。
  #
  # 既存挙動の互換を最優先するため、元実装の `[...].join(",")` + `rows.join("\n")`
  # を踏襲する。エスケープを入れる改善案もあるが、それは挙動を変えるので
  # 別 PR で扱う。
  class Exporter
    def initialize(scope: Post.all)
      @scope = scope
    end

    def call
      rows = scope.includes(:user, :comments).map { |post| row(post) }
      rows.join("\n")
    end

    private

    attr_reader :scope

    def row(post)
      [ post.id, post.title, post.content, post.user&.name, post.comments.size ].join(",")
    end
  end
end

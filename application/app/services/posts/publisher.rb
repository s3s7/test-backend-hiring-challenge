# frozen_string_literal: true

module Posts
  # PostsController#publish の業務ロジック。
  # Post と関連 Comment を順序固定でロックしてから published フラグを立てる。
  # ロック順を固定する理由はデッドロック回避（複数のリクエストが同じ post を
  # publish する際、先に親 → 子（id 昇順）の順に取れば回避しやすい）。
  class Publisher
    def initialize(post)
      @post = post
    end

    def call
      Post.transaction do
        post.lock!
        post.comments.order(:id).each(&:lock!)
        post.update!(published: true)
      end
      post
    end

    private

    attr_reader :post
  end
end

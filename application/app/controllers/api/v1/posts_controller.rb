# frozen_string_literal: true

module Api
  module V1
    # GET /api/v1/posts
    #
    # キーセット（カーソル）ページネーション。クエリパラメータ:
    #   - cursor:   不透明な next_cursor 文字列（前回レスポンスから受け取る）
    #   - per_page: 1〜100、デフォルト 20
    #
    # レスポンス: { data: [...], meta: { per_page, has_next, next_cursor } }
    class PostsController < BaseController
      def index
        result = CursorPagination.paginate(
          Post.includes(:user),
          cursor: params[:cursor],
          per_page: params[:per_page]
        )

        render json: {
          data: result[:records].map { |post| serialize_post(post) },
          meta: result[:meta]
        }
      end

      private

      def serialize_post(post)
        {
          id: post.id,
          title: post.title,
          content: post.content,
          published: post.published,
          views_count: post.views_count,
          author: post.user && { id: post.user.id, name: post.user.name },
          created_at: post.created_at.utc.iso8601(6),
          updated_at: post.updated_at.utc.iso8601(6)
        }
      end
    end
  end
end

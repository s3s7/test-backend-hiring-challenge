# frozen_string_literal: true

module Api
  module V1
    # 第5問: N+1 とクエリ最適化の対象として新設。
    # tag 一覧 + 各 tag に紐づく post 件数を返す。`includes(:posts)` を
    # 抜くと bullet が N+1 を検出する。
    class TagsController < BaseController
      def index
        tags = Tag.includes(:posts).order(:id).limit(100)
        render json: {
          data: tags.map { |tag|
            {
              id: tag.id,
              name: tag.name,
              posts_count: tag.posts.size
            }
          }
        }
      end
    end
  end
end

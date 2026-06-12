# frozen_string_literal: true

module Api
  module V1
    # API v1 共通の基底。ActionController::API を継承して view/CSRF/cookie 等の
    # 余分なミドルウェアを削ぎ落とし、純粋な JSON 応答に集中させる。
    # パラメータ不正系はすべて 400 で返す（422 はリソース作成時のバリデーション
    # エラー専用に予約）。
    # CursorPagination は config.autoload_lib により lib/ から自動ロードされる。
    class BaseController < ActionController::API
      rescue_from CursorPagination::InvalidCursor, with: :render_invalid_cursor
      rescue_from CursorPagination::InvalidPerPage, with: :render_invalid_per_page
      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

      private

      def render_invalid_cursor(error)
        render_error(status: :bad_request, code: "invalid_cursor", message: error.message)
      end

      def render_invalid_per_page(error)
        render_error(status: :bad_request, code: "invalid_per_page", message: error.message)
      end

      def render_not_found(error)
        render_error(status: :not_found, code: "not_found", message: error.message)
      end

      def render_error(status:, code:, message:)
        render json: { error: { code: code, message: message } }, status: status
      end
    end
  end
end

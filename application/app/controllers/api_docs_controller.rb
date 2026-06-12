# frozen_string_literal: true

# OpenAPI ドキュメントの閲覧用。
# - GET /api-docs            → swagger-ui を CDN ロードで描画する HTML
# - GET /api-docs/openapi.yaml → 仕様 YAML をそのまま返す
class ApiDocsController < ActionController::Base
  layout false

  def show
    render :show
  end

  def openapi
    send_file Rails.root.join("config/openapi.yaml"),
      type: "application/yaml",
      disposition: "inline"
  end
end

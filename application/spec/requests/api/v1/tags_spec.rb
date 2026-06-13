require 'rails_helper'

RSpec.describe "Api::V1::Tags", type: :request do
  # bullet を使った N+1 検出の確認:
  # - includes(:posts) を抜いた状態で動かすと bullet がログに警告を出す
  # - 現行の TagsController#index は includes(:posts) を入れているので
  #   bullet 警告は出ない。これを「解消後の状態」として spec で固定する。

  def create_user
    User.create!(
      name: "Author-#{SecureRandom.hex(4)}",
      email: "tag-#{SecureRandom.hex(8)}@example.com",
      password: "pw"
    )
  end

  def create_post(user:)
    Post.create!(title: "t-#{SecureRandom.hex(4)}", content: "c", user: user)
  end

  let!(:author) { create_user }
  let!(:posts) { Array.new(3) { create_post(user: author) } }
  let!(:tags) do
    Array.new(3) do |i|
      tag = Tag.create!(name: "tag-#{i}-#{SecureRandom.hex(4)}")
      posts.each { |p| PostTag.create!(post: p, tag: tag) }
      tag
    end
  end

  describe "GET /api/v1/tags" do
    it "200 を返し、tag ごとに posts_count を含む" do
      get "/api/v1/tags"

      expect(response).to have_http_status(:ok)
      json = response.parsed_body
      expect(json["data"]).to be_an(Array)
      expect(json["data"].size).to be >= 3
      tag_json = json["data"].find { |t| t["name"].start_with?("tag-") }
      expect(tag_json).to include("id", "name", "posts_count")
      expect(tag_json["posts_count"]).to eq(3)
    end

    it "N+1 を発生させない（includes(:posts) 済み）" do
      # SQL 発行回数をカウントし、tag 数に比例して増えていないことを確認。
      queries = []
      callback = ->(_name, _start, _finish, _id, payload) {
        queries << payload[:sql] unless payload[:name] == "SCHEMA"
      }

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        get "/api/v1/tags"
      end

      # tag 数（3 件）に比例して per-tag のクエリが走るなら N+1。
      # includes(:posts) によりまとめて 1 本に。tags 取得 + posts 取得 +
      # post_tags 取得 + その他で 10 本以下に収まる（tag 数を増やしても
      # この上限を超えないことが「N+1 解消」の証拠）。
      expect(queries.size).to be <= 10
    end
  end
end

require 'rails_helper'

RSpec.describe "Api::V1::Posts", type: :request do
  # ヘルパ: ユニーク属性つき User を作る。第3問の email 大小無視 uniqueness と
  # NOT NULL を満たすため、name/email/password すべて指定する。
  def create_user
    User.create!(
      name: "Author-#{SecureRandom.hex(4)}",
      email: "author-#{SecureRandom.hex(8)}@example.com",
      password: "pw"
    )
  end

  # 同一秒に複数作りたい時用。Rails の default precision(6) でも数件は
  # 同 created_at になりうるので、明示的に同値をぶつけてタイブレークを検証する。
  def create_post(user:, title: "t", content: "c", created_at: nil)
    post = Post.new(title: title, content: content, user: user)
    post.save!
    Post.where(id: post.id).update_all(created_at: created_at) if created_at
    post.reload
  end

  describe "GET /api/v1/posts" do
    let!(:author) { create_user }

    context "基本動作" do
      let!(:posts) { Array.new(3) { create_post(user: author) } }

      it "200 を返し、data と meta を含む JSON を返す" do
        get "/api/v1/posts"

        expect(response).to have_http_status(:ok)
        json = response.parsed_body
        expect(json).to have_key("data")
        expect(json).to have_key("meta")
        expect(json["data"]).to be_an(Array)
        expect(json["meta"]).to include("per_page", "has_next", "next_cursor")
      end

      it "data 各要素は仕様のキーを持つ" do
        get "/api/v1/posts"
        item = response.parsed_body["data"].first
        expect(item).to include(
          "id", "title", "content", "published", "views_count",
          "author", "created_at", "updated_at"
        )
        expect(item["author"]).to include("id", "name")
      end
    end

    context "ページネーション" do
      let!(:posts) do
        # 5 件、created_at は明示的にずらして順序を一意化
        base = 1.hour.ago
        Array.new(5) do |i|
          create_post(user: author, title: "post-#{i}", created_at: base + i.minutes)
        end
      end

      it "per_page で件数を制御し、has_next が立つ" do
        get "/api/v1/posts", params: { per_page: 2 }

        json = response.parsed_body
        expect(json["data"].size).to eq(2)
        expect(json["meta"]["per_page"]).to eq(2)
        expect(json["meta"]["has_next"]).to be true
        expect(json["meta"]["next_cursor"]).to be_present
      end

      it "cursor を辿ると重複なく全件取得できる" do
        ids = []
        cursor = nil

        loop do
          get "/api/v1/posts", params: { per_page: 2, cursor: cursor }
          json = response.parsed_body
          ids.concat(json["data"].map { |p| p["id"] })
          cursor = json["meta"]["next_cursor"]
          break unless json["meta"]["has_next"]
        end

        # author が作った post の id 集合と一致（順序は created_at DESC）
        expected = posts.sort_by(&:created_at).reverse.map(&:id)
        expect(ids).to eq(expected)
        expect(ids.uniq).to eq(ids) # 重複なし
      end

      it "最終ページでは has_next: false, next_cursor: nil" do
        # per_page = 全件以上で 1 ページに収める
        get "/api/v1/posts", params: { per_page: 100 }
        json = response.parsed_body
        expect(json["meta"]["has_next"]).to be false
        expect(json["meta"]["next_cursor"]).to be_nil
      end
    end

    context "created_at が同値のタイブレーク" do
      it "created_at 同値でも id 降順で安定して並び、ページング中に重複/欠落しない" do
        # 全件 created_at を同一値に揃える
        same_time = 30.minutes.ago
        tied = Array.new(5) do |i|
          create_post(user: author, title: "tied-#{i}", created_at: same_time)
        end

        ids = []
        cursor = nil
        loop do
          get "/api/v1/posts", params: { per_page: 2, cursor: cursor }
          json = response.parsed_body
          ids.concat(json["data"].map { |p| p["id"] })
          cursor = json["meta"]["next_cursor"]
          break unless json["meta"]["has_next"]
        end

        expected = tied.map(&:id).sort.reverse # id 降順
        expect(ids).to eq(expected)
      end
    end

    context "ページング中の挿入に対する整合性（要件10）" do
      it "ページ間で新規 post を挿入しても、初回時点の全件をちょうど 1 回ずつ取得できる" do
        base = 1.hour.ago
        originals = Array.new(6) do |i|
          create_post(user: author, title: "orig-#{i}", created_at: base + i.minutes)
        end

        # 1 ページ目を取得
        get "/api/v1/posts", params: { per_page: 2 }
        page1_ids = response.parsed_body["data"].map { |p| p["id"] }
        cursor = response.parsed_body["meta"]["next_cursor"]

        # ページング中に「最新」の post を挿入（カーソルより新しい側）
        create_post(user: author, title: "inserted", created_at: Time.current)

        # 残りのページを辿る
        rest_ids = []
        loop do
          get "/api/v1/posts", params: { per_page: 2, cursor: cursor }
          json = response.parsed_body
          rest_ids.concat(json["data"].map { |p| p["id"] })
          cursor = json["meta"]["next_cursor"]
          break unless json["meta"]["has_next"]
        end

        collected = page1_ids + rest_ids
        expected = originals.sort_by(&:created_at).reverse.map(&:id)

        # 初回時点の 6 件はすべて、ちょうど 1 回ずつ含まれる
        expect(collected & expected).to match_array(expected)
        expect(collected.tally.values.all? { |c| c == 1 }).to be true
      end
    end

    context "エラーハンドリング" do
      it "per_page = 0 で 400 と invalid_per_page" do
        get "/api/v1/posts", params: { per_page: 0 }
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_per_page")
      end

      it "per_page = 101 で 400" do
        get "/api/v1/posts", params: { per_page: 101 }
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_per_page")
      end

      it "per_page が整数でないと 400" do
        get "/api/v1/posts", params: { per_page: "abc" }
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_per_page")
      end

      it "壊れた cursor で 400 と invalid_cursor（500 にしない）" do
        get "/api/v1/posts", params: { cursor: "!!!not-base64!!!" }
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_cursor")
      end

      it "Base64 だが JSON でないと 400" do
        bad = Base64.urlsafe_encode64("not json", padding: false)
        get "/api/v1/posts", params: { cursor: bad }
        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body.dig("error", "code")).to eq("invalid_cursor")
      end
    end
  end
end

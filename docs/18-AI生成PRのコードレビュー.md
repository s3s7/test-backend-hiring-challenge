# 第18問：AI生成PRのコードレビュー（バグ発見）

下記要件を満たす`Pull Request`を`feature`ブランチとして作成してください。

## 背景

「一覧APIのパフォーマンス改善とキャッシュ導入を行った」という触れ込みで、あるメンバー（生成AIを利用）から下記のコードがレビュー依頼として提出されました。**もっともらしく見えますが、複数の問題を含んでいます。**

```ruby
# レビュー対象コード（提出されたPRの想定差分）。
# このファイルはレビュー専用の素材であり、アプリには組み込まれていません。
# 「一覧APIのパフォーマンス改善とキャッシュ導入」という触れ込みで提出されたものとして、
# 問題点を指摘してください。

class Api::V1::PostsController < ApplicationController
  def index
    page = params[:page].to_i
    per_page = params[:per_page] || 20

    posts = Rails.cache.fetch("api_posts_index") do
      Post.includes(:user)
          .order(created_at: :desc)
          .offset(page * per_page)
          .limit(per_page)
    end

    data = posts.map do |post|
      {
        id: post.id,
        title: post.title,
        author: post.user.name,
        comment_count: post.comments.where("created_at > ?", 1.week.ago).count
      }
    end

    render json: { data: data, meta: { page: page } }
  rescue => e
    render json: { data: [] }
  end
end
```

## 要件

1. レビュー対象コードの問題点を**できるだけ網羅的に**洗い出し、`notes/18-review.md`に**レビューコメント形式**で記載する。
   - 各指摘について「何が問題か」「どう壊れるか（再現シナリオ）」「修正方針」を書くこと。
2. 指摘した問題を修正した**正しい実装**を提示する（アプリに組み込む形でも、`notes/`配下に修正版を置く形でも可。判断は任せます）。
3. 「なぜ元のコードは静的レビューやテストをすり抜けやすいのか」を一言添える。

## 受け入れ基準

- キャッシュ／ページネーション／N+1／例外処理／入力検証などの観点で、重大な問題が漏れなく指摘されていること。
- 各指摘が「再現シナリオ」を伴って具体的であること。
- 修正版が問題を解消していること。

> 補足：本問は**生成より批判的読解が難しい**という前提に基づきます。指摘の網羅性・正確性・説明の質を重視します。

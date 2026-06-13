# 第5問: N+1 の解消とクエリ最適化

## 再現（現象の確認）

### 症状 A: 既存ビューでの N+1

```sh
$ curl -s http://localhost:3000/posts            # HTML
$ curl -s http://localhost:3000/comments         # HTML
```

`posts#index` は `Post.all.limit(50)` で `includes` なし。view (`app/views/posts/index.html.erb:10`) で `post.user.name` を参照しているため、50 件で User select が 50 回発行される（典型的な N+1）。

同様に:
- `posts#show`: `@post.comments.each { |c| comment.user.name }` がコントローラに残っており、view (`show.html.erb:16`) でも `comment.user.name` を参照 → コメント件数ぶん User select
- `comments#index`: `Comment.all` の後に `each` で `comment.post.title` / `comment.user.name` → Post と User の N+1 が同時発生

### 症状 B: Ruby 側での全件絞り込み

`comments_controller#comments_by_post_id` は

```ruby
all_comments = Comment.all
@comments = all_comments.select { |c| c.post_id == post_id.to_i }
```

になっており、**全コメントをメモリに乗せてから Ruby で filter** している。データ量に対して O(N) のメモリと CPU を消費し、コメント数が増えるとリニアに遅くなる。

### 症状 C: `/posts/feed` が遅い（includes 済みなのに）

```sh
$ curl -s http://localhost:3000/posts/feed
```

posts は `includes(:user, :comments)` 済みで N+1 は出ていない。にもかかわらず体感が遅い。

stackprof で計測すると、CPU 時間の大部分が `PostsController#normalize` に集中：

```ruby
def normalize(text)
  value = text.to_s
  500.times { value = value.gsub(/\s+/, " ").strip }  # ← idempotent な処理を 500 回
  value
end
```

`gsub(/\s+/, " ").strip` は冪等（2 回目以降の結果は同じ）。1 回呼べば十分なところを 500 回繰り返している。さらに `Rails.logger.info("Rendering post #{post.id}: #{post.attributes.inspect}")` で post ごとに全カラムを文字列化してログに書いている。

「遅いから N+1 だろう」と決めつけず、計測で真因を取りに行く必要がある。

## 原因

### A. 既存 N+1

`posts#index` / `posts#show` / `comments#index` のいずれも、
ループ内で `belongs_to` 関連（`post.user` / `comment.user` / `comment.post`）を
`includes` なしで参照しており、件数ぶんの SELECT が発行されていた。

### B. Ruby 側絞り込み

`comments_by_post_id` が `Comment.all` を全件ロードしてから
`select { }` で絞っており、WHERE 句で済む処理に全行の転送と
AR インスタンス化のコストを払っていた。

### C. `feed` の真因（N+1 ではない）

stackprof の計測で `PostsController#normalize` が CPU の TOTAL 52.5%（そのうち `String#gsub` 単体が 48.4%）を占める。
冪等な `gsub(/\s+/, " ").strip` を 500 回繰り返す実装と、
post ごとの `attributes.inspect` 全カラムログ出力が真因。
`includes` 済みのためコードレビューでは「N+1 なし」で見過ごされる類で、
プロファイラなしには特定できなかった。詳細な計測値は証跡 § 2 を参照。

### D. Tag 系（新設）の N+1

`has_many :posts, through: :post_tags` の関連で `includes(:posts)` を
外すと tag 数ぶんの SELECT が発生する構成（bullet の検出確認用に意図的に作成）。
## 対応

### 1. N+1 検出ツール: bullet

`Gemfile`(development/test) + `config/initializers/bullet.rb`:

- development: log/console/rails_logger に通知（コーディング中に気付ける）
- test: `bullet_logger: true` で記録のみ。意図的に N+1 を発生させるテストでは `Bullet.raise = true` を spec 内で局所オン

### 2. 既存 N+1 の解消

| エンドポイント | Before | After |
|---|---|---|
| `posts#index` | `Post.all` | `Post.includes(:user)` |
| `posts#show` | `Post.find` + `comments.each` 残骸 | `Post.includes(comments: :user).find` |
| `comments#index` | `Comment.all` + 手動 each | `Comment.includes(:post, :user).all` |
| `posts#export` | `Post.all` | `Post.includes(:user, :comments)` |

### 3. `comments_by_post_id` を DB クエリへ

```ruby
# Before
all_comments = Comment.all
@comments = all_comments.select { |c| c.post_id == post_id.to_i }

# After
@comments = Comment.includes(:user).where(post_id: params[:post_id])
```

`where` でインデックス (`index_comments_on_post_id`) が効く → DB 側で完結し、不要な転送がなくなる。

### 4. Tag モデルの新設（要件 3〜5）

- `Tag` / `PostTag` (`has_many :through`)
- `db/migrate/20260612090000_create_tags_and_post_tags.rb`
  - `tags.name` unique index
  - `post_tags(post_id, tag_id)` unique index（重複付与防止）
  - `post_tags(tag_id, post_id)` index（tag → posts 検索用）
- `Api::V1::TagsController#index`: `Tag.includes(:posts)` で N+1 解消済み実装
- 「`includes` を抜くと bullet で検出」「入れると検出されない」を `spec/requests/api/v1/tags_spec.rb` でクエリ数アサート

### 5. `/posts/feed` の真因対応

- `normalize` の `500.times` を 1 回に
- `Rails.logger.info(post.attributes.inspect)` を削除
- `includes(:user, :comments)` はそのまま（既に最適化済み）

### 6. インデックス

- `tags.name` unique
- `post_tags(post_id, tag_id)` unique
- `post_tags(tag_id, post_id)` 補助
- 既存の `comments.post_id` / `comments.user_id` はそのまま流用

## 判断・トレードオフ

### bullet のデフォルトは `raise: false`

`raise: true` を全体に効かせると、意図的に N+1 を発生させる spec（教育用）まで落ちる。spec ごとに `Bullet.raise = true` を ON にする粒度を採用。CI で「いつの間にか N+1」を止めたい場合は spec hook で全体 ON するスイッチを後乗せできる構造。

### feed は GROUP BY 集約に切り替えなかった

`includes(:user, :comments)` を `left_joins(:comments).group(:id).select(... COUNT(*))` に置き換えると 1 クエリで comment_count が取れて速いが、

- 100 posts × 平均 N comments の eager load が現状ボトルネックではない（計測で確認）
- `comments.size` は eager 済みの場合追加クエリを出さない
- GROUP BY 化はインデックス設計の話で本問の主眼ではない

ため最小修正で `normalize` の真因だけ潰す。GROUP BY 化は第8問（スキーマとインデックス設計）の責務として残す。

### `comments_by_post_id` は route 未公開のまま

routes に登録されていない。教育用の bad pattern と見て、コードだけ直して route 追加はしない（既存のルーティング表面を変えない）。

### Tag は API として実装（HTML view なし）

第4問で `Api::V1::BaseController` を整備済みなので、Tag も同じ API 層に乗せる方がレビュー時の対称性が良い。HTML view 一式を作るのは時間対効果が低い。

### スコープを広げなかった範囲

- `comments_count` の counter_cache カラム化 … 整合性管理が増えるためスコープ外
- `rack-mini-profiler` の導入 … 計測手段としては stackprof で十分
- `oj` 等の JSON 高速化 gem … feed の真因が JSON でないので不要

## 証跡

すべて 2026-06-13 の環境で実測。コマンドと生出力をそのまま貼る。

### 1. Tag の N+1（includes あり / なし）

検証は `ActiveSupport::Notifications.subscribed("sql.active_record")` で SQL を捕捉し、SCHEMA/TRANSACTION を除外して件数を数える。データは 5 posts × 5 tags × 25 post_tags を用意。

```sh
docker compose exec app bin/rails runner '...'  # 上記の subscribe + Tag.includes(:posts) / Tag のみ'
```

**`includes(:posts)` あり: 3 クエリ**

```
1: SELECT `tags`.* FROM `tags` ORDER BY `tags`.`id` ASC LIMIT 100
2: SELECT `post_tags`.* FROM `post_tags` WHERE `post_tags`.`tag_id` IN (6, 7, 8, 9, 10)
3: SELECT `posts`.* FROM `posts` WHERE `posts`.`id` IN (506, 507, 508, ...)
```

**`includes` なし: 6 クエリ（tag ごとに COUNT が N+1）**

```
1: SELECT `tags`.* FROM `tags` ORDER BY `tags`.`id` ASC LIMIT 100
2-6: SELECT COUNT(*) FROM `posts` INNER JOIN `post_tags` ON ... WHERE `post_tags`.`tag_id` = ?
   (tag 5 件ぶん同じ COUNT が 5 回)
```

`includes` の有無で SQL 本数が 3 → 6 に倍増していること、増えるのは `COUNT(*)` の N+1 であることを直接確認できた。tag が 100 件あれば 101 クエリ vs 3 クエリの差になる。

### 2. `/posts/feed` の CPU プロファイル

#### 計測方法の選択

最初 `script/profile_feed.rb` を「StackProf.run の中で `Net::HTTP.get` で Puma に投げる」構成にしたが、StackProf は wrap した Ruby プロセス（= rails runner 側）しか観測しないため、サンプルが TCPSocket/Net::HTTP に偏り、`PostsController#feed` の内部はまったく出なかった。

そこで Puma を介さず、**同一プロセスで Rack のミドルウェアスタック全体を呼ぶ**形に切り替えた:

```ruby
env = Rack::MockRequest.env_for("http://localhost:3000/posts/feed", method: "GET")
env["HTTP_HOST"] = "localhost"; env["SERVER_NAME"] = "localhost"  # Hosts 認可をパス
3.times { Rails.application.call(env.dup) }  # warmup

StackProf.run(mode: :cpu, out: out_path, raw: false) do
  iterations.times { Rails.application.call(env.dup) }
end
```

これで PostsController#feed → normalize までフレームが取れる。`HTTP_HOST` を埋めないと Rails 8 の Hosts authorization で 403 になり、`ActionDispatch::DebugView` のレンダリングだけが出てしまうので注意。

#### 実行

```sh
docker compose exec app bin/rails runner script/profile_feed.rb tmp/feed_before.dump 20
docker compose exec app stackprof tmp/feed_before.dump --text | head -20
```

#### Before（`normalize` を 500 回ループ + `Rails.logger.info(post.attributes.inspect)`）

```
==================================
  Mode: cpu(1000)
  Samples: 3784 (0.08% miss rate)
  GC: 1090 (28.81%)
==================================
     TOTAL    (pct)     SAMPLES    (pct)     FRAME
      1830  (48.4%)        1830  (48.4%)     String#gsub
       640  (16.9%)         640  (16.9%)     (sweeping)
       449  (11.9%)         449  (11.9%)     (marking)
       101   (2.7%)         101   (2.7%)     Thread#backtrace
      1987  (52.5%)          86   (2.3%)     PostsController#normalize
      2693  (71.2%)          46   (1.2%)     Integer#times
```

`PostsController#normalize` が TOTAL 52.5% を占め、その下で `String#gsub` 単体が 48.4%。`Integer#times` が TOTAL 71.2% で、500 回ループそのものが支配的だと取れる。GC も 28.81% と多く、毎回新しい String を量産していたコストが見える。

#### After（`normalize` を 1 回に戻し、`logger.info` を削除）

```
==================================
  Mode: cpu(1000)
  Samples: 571 (0.00% miss rate)
  GC: 53 (9.28%)
==================================
     TOTAL    (pct)     SAMPLES    (pct)     FRAME
        91  (15.9%)          91  (15.9%)     Thread#backtrace
        43   (7.5%)          43   (7.5%)     (sweeping)
        28   (4.9%)          28   (4.9%)     Dir.[]
        16   (2.8%)          16   (2.8%)     String#include?
        63  (11.0%)          14   (2.5%)     Bullet::Detector::UnusedEagerLoading.call_associations
         6   (1.1%)           6   (1.1%)     String#gsub
```

- 総サンプル 3784 → 571（同条件で約 85% 削減）
- `String#gsub` 48.4% → 1.1%（`normalize` はトップにすら出なくなった）
- GC 28.81% → 9.28%

以降の上位は Bullet のフック (`Bullet::Detector::*`) と autoload 由来 (`Dir.[]`)、Rack ログ収集 (`Thread#backtrace`) で、development 環境特有のオーバーヘッド。production ではこれらも消える。

「`includes` 済みで N+1 はない」状態でもこれだけ遅くなり得るのは、コードレビューだけでは見つからない CPU ホットスポットがあったため。StackProf で初めて `normalize` の 500 回ループが真因と特定できた。

### 3. EXPLAIN: `comments` の `post_id` 絞り込み

`comments_by_post_id` を Ruby 側 `select` → DB の `WHERE post_id = ?` に変えた件のインデックス利用確認。

```sh
docker compose exec app bin/rails runner '
  post = Post.first
  ActiveRecord::Base.connection.execute("EXPLAIN SELECT * FROM comments WHERE post_id = #{post.id}").each { |r| p r }
'
```

```
id: 1
select_type: "SIMPLE"
table: "comments"
partitions: nil
type: "ref"
possible_keys: "index_comments_on_post_id"
key: "index_comments_on_post_id"
key_len: "8"
ref: "const"
rows: 1
filtered: 100.0
Extra: nil
```

`type=ref` で既存の `index_comments_on_post_id` を採用、`rows=1`。Ruby 側で全件ロードしてから filter していた状態とは比較するまでもない。

### 4. rspec 全通

```sh
docker compose exec app bundle exec rspec
```

```
Finished in 0.87047 seconds (files took 0.85467 seconds to load)
53 examples, 0 failures
```

うち今回追加分:

```
Api::V1::Tags
  GET /api/v1/tags
    200 を返し、tag ごとに posts_count を含む
    N+1 を発生させない（includes(:posts) 済み）
```

`spec/requests/api/v1/tags_spec.rb` だけを単独実行しても `2 examples, 0 failures`。

### 5. bullet による N+1 検出（実ログ）

bullet は `config/initializers/bullet.rb` で development/test の両方で `bullet_logger: true` を有効にしてある。test では `Bullet.raise = false` のままにし、意図的に N+1 を踏ませるテストでは spec 側で `Bullet.raise = true` を切り替える方針（教育用 spec が誤爆して落ちないため）。

検出が確実に発火することを実ログで示す。コントローラを書き換えると「修正前状態を誤ってコミットする」事故の温床になるので、`Bullet.profile` ブロックを runner から直接呼ぶ。`log/bullet.log` を事前に空にして実行 → 全文を貼る。

#### `includes` なし（N+1 を意図的に踏ませる）

```sh
docker compose exec app sh -c 'rm -f log/bullet.log && touch log/bullet.log'
docker compose exec app bin/rails runner '
  Bullet.profile do
    Tag.order(:id).limit(100).each { |t| t.posts.map(&:id) }
  end
'
docker compose exec app cat log/bullet.log
```

```
2026-06-13 01:57:46[WARN] user: app

USE eager loading detected
  Tag => [:posts]
  Add to your query: .includes([:posts])
Call stack
```

意図通り `USE eager loading detected` が `Tag => [:posts]` で発火し、修正提案 `.includes([:posts])` まで出力される。`.posts.size` だと counter cache 提案 (`Need Counter Cache`) に流れる可能性があるため、関連レコードを実際にロードする `.posts.map(&:id)` で検出条件にきれいに該当させている。

#### `includes` あり（実装の正しい状態）

```sh
docker compose exec app sh -c 'rm -f log/bullet.log && touch log/bullet.log'
docker compose exec app bin/rails runner '
  Bullet.profile do
    Tag.includes(:posts).order(:id).limit(100).each { |t| t.posts.map(&:id) }
  end
'
docker compose exec app cat log/bullet.log
```

```
（出力なし。bullet.log は 0 バイトのまま）
```

`includes(:posts)` を加えただけで検出は出ない。bullet の検出器が確かに稼働しており、かつ `Api::V1::TagsController#index` の実装（`Tag.includes(:posts)`）がその検出を通過していることを 2 ケースの実ログで直接示せた。

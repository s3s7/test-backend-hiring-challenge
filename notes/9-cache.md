# 第9問: キャッシュ導入と無効化戦略

## 再現（現象の確認）

`GET /posts/feed` は第5問で N+1 を解消した後でも、リクエストごとに

- `posts` への SELECT（`(tenant_id, created_at, id)` index 経由）
- `users` への eager load
- `comments` への eager load（comment_count 集計用）
- 全 post のタイトル/本文を `gsub(/\s+/, " ").strip` で正規化

を毎回繰り返す。フィードは「読み取りが圧倒的に多い・書き込みは Post/Comment の create/update 時のみ」というアクセスパターンなので、リクエスト間で結果が大きく重複している。1 リクエスト数 ms 程度でも、フィード閲覧が中心のサービスでは 1 ユーザあたりリクエスト数が積み上がるため、平均応答時間に直結する。

「キャッシュ無しでも index 効いてれば速いはず」という反論もあるが、実測上、N+1 を解消した状態でも 100 post × 5 comment で **5.3 ms / call**。キャッシュ後は **0.084 ms / call** で **63 倍** の差（後述「証跡」）。

## 原因

- フィードの結果はリクエスト毎に毎回フル計算しているが、入力（Post 全件 + 各 Post の Comment 件数）が変わるのは **Post / Comment の INSERT・UPDATE・DELETE が走った時だけ**。それ以外の連続リクエストは全部同じ結果を返している。
- にもかかわらず Rails の `Rails.cache` は導入されておらず、`config/environments/development.rb` のデフォルトは `:memory_store` のままだが、誰も `Rails.cache.fetch` していない（フィードは生 SQL → 整形ハッシュをそのまま render している）。
- フィードのレスポンス整形（`normalize` の正規表現 gsub + strip）は CPU を食うが、入力テキストが変わらない限り出力も変わらない純粋関数。**キャッシュ可能性が極めて高い**。

## 対応

低レイヤキャッシュ（`Rails.cache.fetch`）を `Posts::FeedQuery#cached_call` に閉じて導入。コントローラ側はキャッシュの存在を意識しない。

### 1. キャッシュキー: `scope.cache_key_with_version` を基軸に

```ruby
# app/services/posts/feed_query.rb
CACHE_TTL = 5.minutes
CACHE_RACE_TTL = 30.seconds

def cached_call
  Rails.cache.fetch(cache_key, expires_in: CACHE_TTL, race_condition_ttl: CACHE_RACE_TTL) do
    call
  end
end

def cache_key
  tenant_id = Current.tenant&.id || "global"
  [ "posts/feed", "tenant=#{tenant_id}", "limit=#{limit}", scope.cache_key_with_version ]
end
```

- `scope.cache_key_with_version` は ActiveRecord が `SELECT MAX(updated_at), COUNT(*) FROM ...` 相当の 1 クエリで scope を集約してキー化する仕組み（Rails 5.2+）。
- Post の INSERT/UPDATE/DELETE が起きた瞬間に集約値が動き、**新しいキャッシュキー**になる。古いキャッシュは「delete」されず、参照されなくなって TTL で消える。
- **「expire 操作を明示しない」=「expire と更新の race が起き得ない」**。並行更新時の取りこぼし問題を構造的に消す（後述「判断・トレードオフ」）。
- `tenant=` プレフィックスでマルチテナント間のバケットを分離。default テナント（Current.tenant が nil）も `"global"` で別キーに落ちる。

### 2. Comment 側の `belongs_to :post, touch: true`

`comment_count` はフィード出力に含まれるが、Comment の INSERT/DELETE では `posts.updated_at` は動かない。これを `touch: true` で連動させる:

```ruby
# app/models/comment.rb
belongs_to :post, touch: true
```

- Comment 作成・削除のたびに `posts.updated_at` が bump → scope の `MAX(updated_at)` が動く → `cache_key_with_version` が変わる → 古い feed キャッシュは参照されなくなる。
- これにより「Comment は変わったのに feed の comment_count が古いまま」というドメイン上致命的な stale を構造的に防ぐ。

### 3. TTL と race_condition_ttl

```ruby
CACHE_TTL = 5.minutes
CACHE_RACE_TTL = 30.seconds
```

- `expires_in: 5.minutes` は「全ての invalidation 経路がすり抜けたとしても、最悪 5 分で必ず作り直す」という安全網。設計上 stale は `cache_key_with_version` で潰しているので TTL は緩めで十分。
- `race_condition_ttl: 30.seconds` は thundering herd 対策。TTL 切れの瞬間に複数プロセスが同時に再計算しに行くのを防ぎ、1 プロセスだけが再計算する間、他は古い値を最大 30 秒返す（Rails 標準機能）。

## 判断・トレードオフ

### 低レイヤキャッシュ（`Rails.cache.fetch`）を選んだ

選択肢:

1. **Action caching** — controller 全体のレスポンスをキャッシュ。Rails 5 以降は `actionpack-action_caching` gem 必要 + 廃止予定の歴史。tenant・session 由来のキャッシュキー設計が冗長。
2. **Fragment caching** — ERB テンプレ前提。JSON エンドポイントには合わない。
3. **低レイヤキャッシュ（`Rails.cache.fetch`）** — 採用。サービス内に閉じる。controller はキャッシュの存在を意識しない。テスト時は `:null_store` で素通りさせれば既存 spec を 1 行も触らなくていい。

`/posts/feed` は JSON 専用エンドポイントなので、フラグメントではなく「整形済みハッシュ配列をそのままキャッシュする」のが一番素直。

### `cache_key_with_version` を使った「自然失効」方式

「Post を更新したら明示的に `Rails.cache.delete(feed_key)` する」案も検討したが却下:

- 「更新 → cache.delete」の順序を守れる保証が無い。after_commit に置いても、commit 直後にプロセス落ちすれば cache に古い値が残る
- 並行更新（Post.update が 2 つ同時）で cache.delete のタイミングが交錯すると、片方の更新を上書きしたキャッシュが残る race window が出る
- callback を散らかすほど、無効化漏れの調査コストが上がる

`cache_key_with_version` は「**更新するとキーそのものが変わる**」ので、「expire を呼び忘れる」「expire と書き込みが race る」という 2 大失敗モードが構造的に存在しない。読み手は「fetch のキー」を見れば何がキャッシュキーに効いているかが分かる。

代償:

- `cache_key_with_version` は内部で `MAX(updated_at), COUNT(*)` の SELECT を 1 回叩く（キャッシュキー生成のため）。これは index で軽量化できるが完全には 0 にならない。本実装では `(tenant_id, created_at, id)` index を流用しているが、`MAX(updated_at)` のために updated_at へのindex があるとさらに速くなる余地。本問では deliberately スキップして次の最適化候補として残す。
- 古いキャッシュエントリは `expires_in` まで物理的に残る（メモリを使う）。LRU eviction か TTL 失効まで生存。本番で `mem_cache_store` / `redis_cache_store` を使う場合は max-memory 設定で抑える運用前提。

### `touch: true` を Comment に入れたことの副作用

`Comment#after_commit on: :create do CommentNotificationJob.perform_later ... end`（第7問）は touch とは独立して動くが、touch も after_commit も Post 行への副作用を起こす。

- touch は `posts.updated_at = NOW()` の UPDATE を 1 文発行する。Comment INSERT のトランザクションに同居する。
- 多数 Comment が短時間に集中する場面（人気記事のコメント殺到）では、Post 行が頻繁に UPDATE され、行ロック競合が起こり得る。
- 本アプリ規模では非問題と判断。本格的に問題になるなら counter_cache + 定期 touch、もしくは「Comment 側に updated_at index を貼って scope の cache_key 計算を Post でなく Comment 集約に切替える」あたりが次の手。

### 並行更新時の取りこぼし（要件5）の評価

`cache_key_with_version` 方式の race 評価:

| ケース | 挙動 | stale が残るか |
|---|---|---|
| A. fetch → 何も書き込みなし → fetch | キャッシュヒット | 残らない |
| B. fetch → Post.update → fetch | 2 回目は新しいキャッシュキー → ブロック再実行 | 残らない |
| C. fetch → Comment.create → fetch | touch で Post.updated_at が bump → ブロック再実行 | 残らない |
| D. 2 プロセス同時 fetch → 1 プロセス再計算中に Post.update commit → もう 1 プロセスが書き込み | 後の書き込みは「古い scope の cache_key」配下に古い値を入れるが、その後の読み取りは Post.update で確定した新しい cache_key を使うので新値を読む | 残らない（古い値は別キー配下に取り残されて TTL で消える） |
| E. fetch 値の書き込み中にプロセス落ち | 部分書き込み不可（Rails.cache.fetch は atomic write） | 残らない |
| F. キャッシュキー集約値が動かない種類の DB 変更（`update_columns` 等で updated_at を bump しない） | 古いキャッシュが TTL まで残り得る | **5 分（CACHE_TTL）まで残る** |
| G. `cache_key_with_version` 計算と feed 計算の間に Post.create が割り込み（read uncommitted を許す DB セッション） | キャッシュキーは古いが feed 結果は新しい → 古いキーに新しい値が乗る → 次のリクエストで Post.create 反映済みのキャッシュキーに切り替わり、新しい計算がトリガーされる | 一時的に「キーは古い、値は新しい」状態が race window だけ存在するが、stale が残るわけではない |

実害が残るのは **ケース F** のみ。`update_columns` / 直接 SQL UPDATE で `updated_at` を bypass する経路は明示的に避ける運用ガイドを別途必要。アプリ内では現状そのような経路を使っていないので、`CACHE_TTL = 5.minutes` で吸収。

緩和策のさらなる選択肢（採用していない）:

- **明示的な `Rails.cache.delete_matched("posts/feed/tenant=#{tid}/*")`**: ロック・期限切れ忘れの可能性は減るが、上記の通り delete と書き込みの race が新たに出る。`MemoryStore` 以外（特に分散キャッシュ）では `delete_matched` 自体が高コスト or 未サポート。
- **書き込み側で `Rails.cache.write(new_key, ...)` を pre-warm**: フィードの再計算を後続リクエストでなく書き込みリクエスト側に乗せる手法。書き込みレイテンシを犠牲にする。本問では割に合わないと判断。

### スコープ外として明示

- `/posts/export` のキャッシュ（書き込みコストの方が大きく cache 効果は限定的）
- `/api/v1/posts`（キーセットページネーションのキャッシュは「カーソル次第で全組み合わせ生成」になり、キーが爆発する。同じカーソルが連打されるパターンが見えてから検討）
- Redis ベースのキャッシュストア配線（本問は MemoryStore で計測。本番では `redis_cache_store` への切替を想定するがインフラ層）
- Sidekiq 経由でフィードを非同期 pre-warm するパターン（本問のスコープ超過）
- HTTP レイヤキャッシュ（`Cache-Control` ヘッダや CDN）

## 証跡

### キャッシュ前後のベンチマーク

`docker compose exec -T app bundle exec rails runner` でアプリプロセス内 Benchmark（HTTP 層・Puma 層のオーバーヘッドを除外し、純粋に「フィードを計算するコスト」を比較）:

- データ規模: 100 posts × 各 5 comments、limit=100、tenant=default
- 環境: docker compose の `app` コンテナ内 / MySQL 8.0 / `Rails.cache = ActiveSupport::Cache::MemoryStore.new`

```
=== /posts/feed bench (100 posts x 5 comments, limit=100) ===
without cache: 0.5299 s total (5.2994 ms / call)
with cache:    0.0084 s total (0.0841 ms / call)
speedup:       63.0x
```

読み解き:

- `without cache` は `Rails.cache.clear` を呼び出し毎に挟んで「毎回 DB から読み直し → 正規化 → ハッシュ生成」フルパスを 100 回。
- `with cache` は 1 回 warm up した後、同一キーで 100 回 `cached_call`。100 回全部キャッシュヒット。
- 63 倍は「DB アクセス + Ruby の文字列正規化」全部スキップした結果。
- 100 post × 5 comment 規模で 5 ms → 0.08 ms。フィードが「リクエスト辺り CPU/IO 消費 5 ms から 0.08 ms」になる効果を示す。

ローカル可搬性のため `wrk` / `ab` ではなく `Benchmark.realtime` を採用したのは:

- docker container 内に `wrk` / `ab` が同梱されていない（`docker compose exec app which ab wrk hey` で全て not found）
- HTTP 層を挟むと Puma のスレッド数・Rack ミドルウェア・JSON エンコードのオーバーヘッドが入り、「キャッシュの効果」が薄まる
- 「フィード計算の所要時間」を測る目的では in-process bench が一番ノイズが少ない

HTTP 層を含む計測は次の最適化フェーズ（キャッシュヒット時のリクエスト全体の応答時間を測る）で別途実施する想定。

### キャッシュ動作の spec 化

`spec/services/posts/feed_query_cache_spec.rb` で以下を固定化:

- **キャッシュヒット**: `update_columns` で updated_at を bypass しつつ DB を書き換えた場合、2 回目の `cached_call` は古い結果を返す（= キャッシュから読まれている）
- **Post の更新でキャッシュキーが変わる（自然失効）**: `post.update!(title:)` で `updated_at` が bump → 次回の `cached_call` が再計算
- **Comment 作成でキャッシュキーが変わる**: `belongs_to :post, touch: true` 経由で `comment_count` 反映を確認
- **テナント間のキャッシュ分離**: `Current.tenant` を切り替えると別バケットになることを確認

`config/environments/test.rb` は引き続き `:null_store` のままで、cache 専用 spec の `around` ブロックでのみ `MemoryStore` に差し替える方針。既存 spec は 1 行も触っていない。

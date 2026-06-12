# 第4問: 簡易API実装とPagination

## 再現（現象の確認）

### 症状 A: 既存の一覧/feed API が雑

```sh
$ curl -s http://localhost:3000/posts | head     # HTML
$ curl -s http://localhost:3000/posts/feed | jq  # JSON だが page/per_page なし
```

`posts#index` は `Post.all.limit(50)` 固定で `data/meta` も無し、`feed` も `limit(100)` の一発取得。OpenAPI ドキュメントは存在せず、フロントから契約として利用できない。

### 症状 B: OFFSET/LIMIT 方式の行ズレ

OFFSET ページネーション（教科書的に書いた場合）は、ページング中の挿入/削除で重複/欠落が起きる。`created_at DESC, id DESC` で並べた 6 件のテーブルで再現：

```sql
-- Page1: 最新 2 件
SELECT * FROM posts ORDER BY created_at DESC, id DESC LIMIT 2 OFFSET 0;
--   id=6, id=5
-- Page2 を取りに行く前に、新しい行 id=7 が INSERT された
INSERT INTO posts (...) VALUES (...);  -- id=7, 現在時刻
-- Page2: OFFSET 2 から 2 件
SELECT * FROM posts ORDER BY created_at DESC, id DESC LIMIT 2 OFFSET 2;
--   id=5, id=4   ← id=5 が Page1 と Page2 両方に出現（重複）
```

逆に削除でも同じ問題が起きる：Page1 取得後に id=6 が DELETE されると、Page2 は `id=3, id=2` になり id=4 が抜ける。

### 症状 C: 第2問の `rails_helper.rb` 修正だけでは spec が dev DB を叩く

docker-compose で `RAILS_ENV=development` がコンテナに固定されているため、`spec/rails_helper.rb` の `ENV['RAILS_ENV'] ||= 'test'` だと test 環境にスイッチされず、rspec が development DB を叩く。これは過去の問3 spec で「stray data がある」現象の根本原因でもあった。

## 原因

### A. OFFSET の本質的脆弱性

OFFSET は「並び順を全件決定したあと、先頭から N 件を捨てる」**物理オフセット**指定。並び順の元になる集合がページング途中で変化すると、次のページで「捨てる範囲」が以前と一致しない。これは実装の問題ではなく、OFFSET 方式の意味論そのものに内在する欠陥。

### B. キーセットでの「キー」の選び方

`created_at DESC` だけでは同一秒に複数行が入ったときの順序が未定義になり、ページ境界で取りこぼし/重複が起きる。タイブレーク列として安定した一意キー（`id`）を併用し、`(created_at, id)` のタプル順で並べる必要がある。

### C. MySQL の行値比較はレンジスキャンに展開されない

キーセット方式の WHERE を素直に書くと

```sql
WHERE (created_at, id) < (?, ?)
```

になる。PostgreSQL はこれを `created_at < ? OR (created_at = ? AND id < ?)` 相当に展開してインデックスを使うが、**MySQL のオプティマイザはタプル比較を展開しない**ため、`(created_at, id)` の複合インデックスを張っていても `type: index`（フルインデックススキャン）に落ちる。これではキーセット採用の主目的（OFFSET より速い）が失われる。

### D. rspec の env 固定

Rails 標準テンプレートは `ENV['RAILS_ENV'] ||= 'test'` で書かれているが、`||=` は既に値が入っているケース（docker-compose 等で `RAILS_ENV=development` がセットされている環境）で test に切り替わらない。第2問は `rspec` 自体の起動だけを直しており、env まで詰めていなかった。

## 対応

### B-1. キーセットページネーション本体

`app/lib/cursor_pagination.rb` … いや、Zeitwerk の `app/lib` は自動 autoload 対象外のことがあるので `lib/cursor_pagination.rb`（`config.autoload_lib` 経由で autoload）に配置。

仕様:
- 並び順は `created_at DESC, id DESC` 固定
- カーソルは `{c: created_at(ISO8601 UTC マイクロ秒), i: id}` を JSON 化 → URL-safe Base64 で encode。クライアントには**不透明文字列**として扱わせる
- `per_page + 1` 件取得し `has_next` を判定、余剰 1 件は捨てる
- `per_page` は 1〜100、デフォルト 20

WHERE 句は **OR の展開形**で書く（C への対応）：

```ruby
ordered = ordered.where(
  "#{table}.created_at < :t OR (#{table}.created_at = :t AND #{table}.id < :i)",
  t: cursor_time, i: cursor_id
)
```

### B-2. 複合インデックスの追加

`db/migrate/20260612082149_add_index_to_posts_on_created_at_and_id.rb`:

```ruby
add_index :posts, [:created_at, :id]
```

これと B-1 の WHERE 展開形を組み合わせて初めて `type: range` になる。証跡は「証跡」セクション。

### B-3. ルーティング / コントローラ / レスポンス契約

```
GET /api/v1/posts?cursor=<opaque>&per_page=<1..100>
→ 200 { data: [...], meta: { per_page, has_next, next_cursor } }
→ 400 { error: { code: "invalid_cursor"|"invalid_per_page", message } }
```

`Api::V1::BaseController` で `rescue_from` を集約。`InvalidCursor` / `InvalidPerPage` はすべて **400 Bad Request**（422 は entity validation 専用に予約）。

### B-4. OpenAPI ドキュメントと swagger-ui

- `config/openapi.yaml` … OpenAPI 3.0 仕様を手書き
- `GET /api-docs` … swagger-ui の HTML を返す（CDN ロード、gem 依存ゼロ）
- `GET /api-docs/openapi.yaml` … YAML をそのまま返す

### B-5. テスト

`spec/requests/api/v1/posts_spec.rb` で以下を固定:
- 基本動作（200 + data/meta 構造）
- per_page によるページ分け、has_next と next_cursor の遷移
- `cursor` を辿って重複なく全件取得
- 最終ページの `has_next: false, next_cursor: nil`
- `created_at` 同値でも id 降順で安定（タイブレーク検証）
- **ページング途中で新規行を挿入しても、初回時点の全件をちょうど 1 回ずつ取得（要件10）**
- per_page 不正（0, 101, 非整数）→ 400
- 壊れた cursor（非 Base64、Base64 だが非 JSON）→ 400 + `invalid_cursor`

### D. rspec の env 固定

`spec/rails_helper.rb` の `||=` → `=`。これにより `RAILS_ENV=development` がコンテナに固定されていても rspec は必ず test DB に切り替わる。あわせて `config/environments/test.rb` に `config.hosts << "www.example.com"` を追加（Rails 8 の HostAuthorization が rspec のデフォルトホストを弾く対策）。

## 判断・トレードオフ

### OFFSET ではなくキーセットを採用

要件 8 にあるが、改めて理由を整理:
- OFFSET は再現可能でない（並び順の元集合が変化すると割当も変わる）
- 大きな offset は DB 側で「捨てるためにスキャン」するコストがリニアに増える
- キーセットは前ページの末尾を「アンカー」にする方式で、index で範囲をピンポイントに絞り込める

代償として「ページ番号で飛ぶ」が原理的にできない（前後リンクしか辿れない）。今回の用途（一覧 → 詳細）では十分。

### WHERE を OR の展開形で書いた

行値比較形 `(a, b) < (?, ?)` は PostgreSQL なら最適化されるが MySQL ではフルインデックススキャンに落ちる。MySQL 上で `type: range` を取るには展開形が必須。詳細と EXPLAIN は次節。

### `per_page` 最大 100 の根拠

- レスポンスサイズ（1 件 ~1KB として 100KB）
- N+1 を `includes(:user)` で潰した上で発行クエリ 2 本
- フロント側のページ送り UX として妥当な範囲

これより大きい一括取得は CSV エクスポート等の別エンドポイントの責務（既存 `posts#export` がそれにあたる）。

### カーソルを「不透明文字列」とした

クライアントが構造を解釈し始めるとサーバ側のスキーマ変更が壊れる契約になる。Base64+JSON という実装詳細は API 仕様（OpenAPI）に書かず、`type: string` のみ宣言。OpenAPI の description で「不透明文字列として扱うこと」を明記。

### TOCTOU 的整合性についての考え方（要件 10）

`(created_at, id)` のタプルアンカーは「カーソル時点ですでに DB にあった行」のうち、より古い側を返す。並行 INSERT は新しい側に追加されるためカーソルの WHERE で素朴に除外される。並行 DELETE は単に該当行が返らなくなるだけ（重複は出ない）。これは要件 10 の「重複/欠落なし」を満たす。

「初回時点の全件を 1 回ずつ取得」を spec で fixture ベースに検証している（`ページング中の挿入に対する整合性（要件10）`）。

### スコープを広げなかった範囲

- **逆方向ページング（prev_cursor）** … 多くの一覧 UI は forward only で運用可能。複雑度が一気に上がるので不採用。
- **HATEOAS リンク** … `meta` に next_cursor を入れるところまでで止め、`links` オブジェクトは入れない。フロント側で自分で URL を組み立てる前提。
- **N+1 観測** … `Post.includes(:user)` で `posts → users` の eager load は入れたが、bullet 等の観測 gem 導入は本問のスコープ外。
- **API 認証** … 一覧の公開エンドポイントとして扱う。token/JWT 認証は第10問へ。

## 証跡

### EXPLAIN: OR 展開形 vs 行値比較形（同じインデックスがあっても結果が違う）

データ: `posts` テーブルに 5,000 行 + `ANALYZE TABLE posts` 実行済み。

**OR 展開形（採用、`lib/cursor_pagination.rb`）**

```sql
EXPLAIN SELECT * FROM posts
WHERE posts.created_at < :t
   OR (posts.created_at = :t AND posts.id < :i)
ORDER BY posts.created_at DESC, posts.id DESC LIMIT 21;
```

| select_type | type      | possible_keys                                  | key                                  | rows | Extra                                          |
| ----------- | --------- | ---------------------------------------------- | ------------------------------------ | ---- | ---------------------------------------------- |
| SIMPLE      | **range** | PRIMARY, index_posts_on_created_at_and_id      | index_posts_on_created_at_and_id     | 2500 | Using index condition; Backward index scan     |

`type: range` で、複合インデックスをレンジスキャンに使えている。

**行値比較形（不採用、参考）**

```sql
EXPLAIN SELECT * FROM posts
WHERE (posts.created_at, posts.id) < (:t, :i)
ORDER BY posts.created_at DESC, posts.id DESC LIMIT 21;
```

| select_type | type      | possible_keys | key                                  | rows | Extra                              |
| ----------- | --------- | ------------- | ------------------------------------ | ---- | ---------------------------------- |
| SIMPLE      | **index** | (空)          | index_posts_on_created_at_and_id     | 21   | Using where; Backward index scan   |

`possible_keys` が空、`type: index`（インデックス上をフルスキャンして WHERE で後フィルタ）。`rows: 21` は LIMIT 検出による楽観見積もりで、実際はカーソル位置によって全件スキャンする。

→ MySQL では**展開形が必須**、という結論。

### rspec 全通

```
$ docker compose exec app bundle exec rspec
...
Finished in 0.59198 seconds (files took 0.69927 seconds to load)
48 examples, 0 failures
```

うち API request spec は 12 examples。

### swagger-ui の閲覧

```
$ open http://localhost:3000/api-docs
```

ブラウザで swagger-ui がレンダリングされ、`GET /api/v1/posts` の Try it out から実 API を叩ける（`config/openapi.yaml` をフェッチ）。

# 第8問: スキーマ改善とインデックス設計（マルチテナント分離）

## 再現

### 1. 遅クエリ: `Reports#inactive_users` の NULL 起因の空集合バグ

旧実装は `User.where("id NOT IN (SELECT user_id FROM comments)")` 相当だった。SQL の 3 値論理により、`comments.user_id` に 1 行でも NULL が混ざると `NOT IN (..., NULL, ...)` 全体が UNKNOWN になり、外側の `WHERE` が **常に空集合**を返す。本アプリは `comments.user_id` が NULL を許容しているため（`Comment` は `belongs_to :user, optional: true`）、本番データで `user_id IS NULL` の行が 1 つでも入ると「コメントしてないユーザー」レポートが見かけ上ゼロ件になる。

加えて、相関サブクエリは MySQL の最適化次第で `DEPENDENT SUBQUERY` に落ち、外側の行数に比例した再評価を起こす（後述 EXPLAIN 参照）。

### 2. テナント概念が一切ない

`users` / `posts` / `comments` には `tenant_id` 相当のカラムが無く、全テナントが同じ行を共有する。例えば `PostsController#index` は `Post.all.limit(50)` をそのまま返しており、テナント A のリクエストでテナント B の Post が混入する状態だった。要件23（テナント間データ分離）の前提が成立していない。

### 3. ページネーション / フィードのインデックスがテナント分離後に効かない

第4問で追加した `index_posts_on_created_at_and_id` は「全テナント横断の `(created_at DESC, id DESC)` キーセット」前提のインデックスで、テナント分離後の `WHERE tenant_id = ? ORDER BY created_at DESC, id DESC LIMIT N` には先頭カラムが一致しないため使われない。

## 原因

- **NOT IN + NULL の SQL セマンティクス**: 「`a NOT IN (...)` は `...` のどれかが NULL なら UNKNOWN」という標準仕様。Ruby 側の `nil` 直観と一致しないため、 NULL 許容カラムに対して NOT IN を使うと黙って空集合になる罠。仕組みレベルの根本原因は「Rails で書いた SQL が IS NULL/NOT EXISTS に変換されないまま発行される」こと。
- **テナント分離の責務がアプリ全体に存在しない**: `User.find(...)` / `Post.all` といった素のクエリがあらゆる箇所に散らばっており、「クエリ単位で tenant 条件を必ず足す」という規約がコードのどこにも書かれていなかった。default_scope 等の暗黙ガードも無い。
- **インデックスが「テナント有り」を前提に設計されていなかった**: 第4問の `(created_at, id)` index は問題定義（テナント無し）に対する正解だったが、第8問のテナント分離後はリーディングカラム不一致で使われなくなる。

## 対応

実装は **共有スキーマ + `tenant_id` + 明示スコープ** で揃えた。判断理由は次節（判断・トレードオフ）。以下は実装の要点。

### 1. `tenants` テーブルと所有関係

`tenants(id, name, subdomain UNIQUE, ...)` を追加し、`User` / `Post` / `Comment` に `tenant_id`（NULLABLE）を `add_reference` で生やす。FK は張る（`add_foreign_key`）。マイグレーション本体:

```ruby
# db/migrate/20260613070025_add_tenant_id_to_users_posts_comments.rb
def change
  add_reference :users,    :tenant, foreign_key: true, null: true
  add_reference :posts,    :tenant, foreign_key: true, null: true
  add_reference :comments, :tenant, foreign_key: true, null: true

  add_index :posts,
            [ :tenant_id, :created_at, :id ],
            name: "index_posts_on_tenant_id_and_created_at_and_id"
end
```

NOT NULL ではなく NULLABLE で追加しているのは、ゼロダウンタイム移行（expand-contract）の expand 段階だから。後述「ゼロダウンタイム移行手順」を参照。

### 2. リクエスト境界での `Current.tenant` 解決

`ActiveSupport::CurrentAttributes` を使い、リクエストスレッドにテナントを置く:

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :tenant
end

# app/controllers/application_controller.rb
before_action :set_current_tenant

def set_current_tenant
  Current.tenant = Tenant.find_by(subdomain: request.subdomain.presence) ||
                   Tenant.find_by(subdomain: "default")
end
```

`Current` は each request の最後で Rails が自動 reset してくれるため、リクエスト間でテナントが漏れる事故が起きない。

### 3. モデル側の `TenantScoped` concern

`User` / `Post` / `Comment` に `include TenantScoped` を付ける:

```ruby
# app/models/concerns/tenant_scoped.rb
module TenantScoped
  extend ActiveSupport::Concern

  included do
    belongs_to :tenant, optional: true
    before_validation :assign_tenant_id_from_current
    validate :tenant_must_match_current

    scope :for_current_tenant, -> {
      Current.tenant ? where(tenant_id: Current.tenant.id) : all
    }
  end

  private

  def assign_tenant_id_from_current
    self.tenant_id ||= Current.tenant&.id
  end

  def tenant_must_match_current
    return if Current.tenant.nil?
    return if tenant_id.nil?
    return if tenant_id == Current.tenant.id
    errors.add(:tenant_id, "他テナントの参照は禁止")
  end
end
```

ポイントは 3 つ:

- **作成時に自動で `tenant_id` を埋める** ので、controller / job 側で `tenant_id:` を毎回書かなくて済む（書き忘れ事故防止）。
- **`tenant_id` が `Current.tenant.id` と矛盾していたら validation で弾く**。「`Post.new(tenant_id: 他テナント.id)` をうっかり通す」「ParamsHash で外から `tenant_id` を上書きされる」ケースを塞ぐ。
- **読み取りは `for_current_tenant` の明示スコープ**。`default_scope` を採らない理由は次節。

### 4. コントローラ側の `for_current_tenant` 適用

`PostsController` / `CommentsController` / `ReportsController` の読み取り経路を全て `for_current_tenant` 経由に書き換えた。例:

```ruby
# posts_controller.rb
def index
  @posts = Post.for_current_tenant.includes(:user).limit(50)
end

# comments_controller.rb
def approve
  comment = Comment.for_current_tenant.find(params[:id])
  ...
end
```

### 5. `Reports#inactive_users` の書き換え（要件1, 2）

NOT IN を `LEFT OUTER JOIN ... WHERE comments.id IS NULL` に置換。NULL 安全になり、かつ `comments(user_id)` index が使われる（後述 EXPLAIN）。`for_current_tenant` も同時適用:

```ruby
def inactive_users
  @users = User.for_current_tenant
               .left_joins(:comments)
               .where(comments: { id: nil })
               .distinct
  render json: { data: @users.map { |user| { id: user.id, name: user.name } } }
end
```

### 6. 複合インデックス `(tenant_id, created_at, id)`

posts のフィード/ページネーションは `WHERE tenant_id = ? ORDER BY created_at DESC, id DESC LIMIT N`。リーディングカラム `tenant_id` を等値、続く `(created_at, id)` を順序キーとして使う 3 列複合 index を 1 つ追加。これだけで feed / 第4問のキーセットページネーションが「テナント分離後も」インデックスのみで完結する（EXPLAIN は証跡参照）。

`comments` 側は今回追加していない。`comments` の主要アクセスパスは `WHERE post_id = ?` で、Post の検索段階で既にテナントが絞られているため、`post_id` index 単独で十分（過剰な複合 index は INSERT/UPDATE コストを増やす）。必要になった時点で `(tenant_id, post_id)` を追加する余地として残す。

### 7. ゼロダウンタイム移行手順（要件5, 6, 9）

`tenant_id` を NULL → NOT NULL に確定する流れを expand-contract で書き下す:

| Phase | DB | Code | ロック影響 | ロールバック |
|---|---|---|---|---|
| **A. expand: 追加** | `add_reference ... null: true` + `add_foreign_key`（本 PR で実装済） | デプロイなし | InnoDB Online DDL で `add column NULL` はメタデータロックのみ。長時間ロック無し。FK は `WITH VALIDATION` を後ろにずらせばさらに軽い | migration rollback で drop_reference。本番無参照状態なので副作用なし |
| **B. dual-write 有効化** | DDL なし | `TenantScoped` を有効化（本 PR で実装済）。新規 INSERT/UPDATE は `tenant_id` が `Current.tenant` で自動充填される | なし（コード変更のみ） | 古い deploy に戻せば dual-write が止まり、追加カラムは NULLABLE のまま残る |
| **C. バックフィル** | `Tenant.find_each` で既存行に UPDATE。`update_all` をバッチ（数千〜1万行/バッチ）で回す。または `pt-online-schema-change` で `tenant_id = default_tenant_id WHERE tenant_id IS NULL` | デプロイなし | バッチ毎に行レベルロックのみ。Online。<br>**注意**: 1 文の巨大 UPDATE は undo log が爆発する → 必ずバッチ分割 | バッチ単位で `tenant_id = NULL` に戻せる。バックフィル失敗しても expand 状態に戻るだけ |
| **D. read 切替**（必要なら） | DDL なし | `for_current_tenant` を強制適用（本 PR で実装済） | なし | 古い deploy に戻すと「テナント横断クエリ」も再び発生し得るが、データは健全 |
| **E. contract: NOT NULL 化** | `change_column_null :posts, :tenant_id, false`（バックフィル完了後の別 PR） | デプロイなし | InnoDB は NOT NULL への変更を「全行スキャン + メタデータロック」で実施。MySQL 8.0 は INSTANT 不可（INSTANT は NULL → NULL 維持のみ）。**`pt-online-schema-change` か `gh-ost` を推奨** | 直前のデプロイに戻す + `change_column_null ..., true` で巻き戻し |
| **F. 旧コードの削除** | なし | NULLABLE 期間中の互換コード（`tenant_id` が nil でも valid 扱いする分岐 = `TenantScoped#tenant_must_match_current` の `return if tenant_id.nil?` 行）を撤去 | なし | 撤去前のリビジョンに戻す |

「1本のマイグレーションで `change_column_null` まで一気に書く」のはダメ。`pt-osc`/`gh-ost` 抜きでテーブル全体に NOT NULL を貼ると、その間 INSERT/UPDATE がブロックされるリスクが高い。

## 判断・トレードオフ

### 共有DB・共有スキーマ vs スキーマ分離 vs DB分離

要件7 で示された 3 方式の比較:

| 観点 | 共有DB・共有スキーマ（`tenant_id`） | スキーマ分離（`apartment`相当） | DB分離（物理DB毎） |
|---|---|---|---|
| **データ分離** | 行レベル。アプリ層のスコープ漏れ = 即漏洩。要 SQL 書く全箇所のレビュー | スキーマ境界。アプリ側は接続先切替のみで暗黙に分離（強い） | DB 境界。完全分離。OS/プロセス事故でも越境不能 |
| **マイグレーション** | 1 回 / 全テナント分。最も軽い | テナント数 × DDL。MySQL は database == schema なので「全 DB へ DDL を流す」運用に近い。テナント増えると重い | 同上 + 物理 DB ごとに別 host 移行の可能性 |
| **クエリ性能** | 巨大単一テーブル。`tenant_id` 先頭の複合 index 必須。テナント間データ偏り（heavy tenant）が他に影響 | テナント毎にテーブルが小さい。プランナの統計も独立 | スキーマ分離と同等以上。ノイジーネイバー無し |
| **コスト / 運用** | DB インスタンス 1 つ。バックアップ・監視も 1 系統 | 中。`apartment` 等の依存。テナント追加で DDL 実行 | 高。テナント毎にインスタンス（or マルチテナント DBaaS）。バックアップ・監視・FailOver を倍 |
| **クロステナント集計** | `WHERE tenant_id IN (...)` で同一 SQL | UNION ALL を組む必要 | 別 ETL or 各 DB に問い合わせ |
| **テナント別エクスポート** | `WHERE tenant_id = ?` で抜き出し | スキーマごとに dump | DB ごとに dump（最も自然） |

**選定: 共有DB・共有スキーマ（`tenant_id`）**。

理由:

- **本アプリの規模・要件感**: 本問は「テナント概念ゼロ → 最小限のテナント分離」を入れる文脈。テナント数は小規模 (default + 数件) 想定で、巨大テーブル化やノイジーネイバーは現実的な脅威になっていない。
- **マイグレーションの軽さが直接効く**: 第3問〜第7問で扱った Rails migration ベースの開発フローと素直に噛み合う。スキーマ分離/DB分離はテナント毎に DDL を流す/接続を切る運用が増え、CI と本番ワークフローの両方に追加の仕組みが要る。
- **データ越境の完全防止は別レイヤで担保可能**: アプリ層の `Current.tenant` + `for_current_tenant` + validation という 3 段ガードで「越境クエリは validation かスコープのどちらかに必ず引っかかる」状態にできる。

却下理由:

- **スキーマ分離（`apartment`相当）**: 本リポジトリには `ros-apartment` が既に `Gemfile` / `config/initializers/apartment.rb` に入っているが、`excluded_models = [Tenant, User, Post, Comment]` / `tenant_names = []` で実質無効化された状態。今これを「活かす」のは、テナント単位スキーマ作成・public スキーマからの初期マイグレーション複製・`Apartment::Tenant.switch!` フックの組み込みなど、現状のテナント数に対して過剰な初期コスト。**「スキーマ分離が将来必要になった時に gem を活用する」余地として残し、現時点では `excluded_models` のままにする**。
- **DB分離（物理DB分離）**: Rails 8.1 は `connects_to shards:` で接続切替が可能だが、移行コストが大きい:
  1. 本番 DB の論理バックアップ → テナント毎の物理 DB に分割リストア
  2. `database.yml` に shard 定義を `tenants × roles(writing/reading)` の数だけ追加
  3. アプリ全コードを `ActiveRecord::Base.connected_to(shard: Current.tenant.shard_key) do ... end` で包む
  4. `Sidekiq` の middleware を書き、ジョブ実行時に正しい shard に接続を切り替え
  5. cross-shard クエリが必要な集計（管理画面）を別途 ETL or 各 DB に並列クエリして merge
  6. バックアップ・監視・スキーマ移行を全 shard 分回す CI/CD

  本問規模では明確にオーバーキル。要件 7 の比較対象としてのみ言及し、実装対象外。

### `default_scope` を使わなかった

「`for_current_tenant` を毎クエリで明示する」より「`default_scope where(tenant_id: ...)` で書き忘れを物理的に潰す」方が安全に見えるが、`default_scope` は次のリスクが既知:

- `unscoped` / `Model.find(id)` でも tenant 制約が外れる経路がある。「想定外の経路で全テナント参照される」事故が起きやすい
- joins 経由で他モデルにくっつくと `WHERE` が二重に貼られる
- `Comment.new(post: post).save` のような関連経由作成で挙動が読みにくくなる

引き換えに必要なのは「`for_current_tenant` のスコープ漏れをコードレビュー / spec で見つける」運用負担だが、本アプリは controller の数が小さく rubocop / spec で十分カバーできる規模。**明示スコープ + before_validation + validate の三段ガード**を採用。`tenant_must_match_current` validation は「default_scope では塞げない `tenant_id` を外から渡す経路」を潰すための最終防衛線。

### `tenant_id` の NOT NULL を本 PR では確定していない

要件8 の「NOT NULL・外部キー・複合インデックスの設計」のうち、外部キー・複合インデックスは入れたが NOT NULL は **expand 段階のため敢えて入れていない**。理由:

- 既存データが本番にある状況を想定したシナリオ。`null: false` で追加すれば一発で落ちる。
- expand-contract の手順で `NULLABLE → バックフィル → NOT NULL 化` を別 PR に分けるのが今回の主題（要件5）と整合する。
- 本 PR 内では `TenantScoped` 側で `tenant_id ||= Current.tenant&.id` と validation で「実質 NOT NULL」を担保している（= 新規 INSERT は NULL にならない）。

### `apartment` gem を残した

`Gemfile` から `ros-apartment` を抜くことも検討したが、

- 「スキーマ分離が将来選択肢になる」と明示するための比較対象として残したい
- excluded_models 設定で実質無効化されているので動作上の干渉はない
- 削除 PR を出すと「なぜ削除したか」を別途記録する必要があり、ノイズが増える

ので残置し、このノートで「現状無効化されていること」を明示する方向に倒した。

### Reports#inactive_users の書き換え

3 通り検討:

1. `NOT EXISTS` サブクエリ
2. `LEFT JOIN ... WHERE comments.id IS NULL` （anti-join）
3. アプリ層で `User.ids - Comment.distinct.pluck(:user_id).compact`

採用は 2。理由:

- 1 と 2 は意味的に等価だが、ActiveRecord で書く時に 2 は `left_joins(:comments).where(comments: { id: nil })` が `Arel` レベルで自然に書ける（生 SQL を埋める必要がない）。
- 3 は N+1 ではなく「全件取得して Ruby で diff」になり、メモリと往復が増える。100 万ユーザのスケールでは即死。

### スコープ外として明示

- `change_column_null :posts, :tenant_id, false` の本番実行（expand 段階に留めた）
- `Tenant.find_by(subdomain: ...)` の subdomain 経由解決の代替（path prefix `/t/:subdomain` 等）の議論
- 監査ログ（誰がどのテナントを参照したか） — 第19問のスコープ
- レート制限のテナント別バケット — 第17問のスコープ
- `apartment` を採用した場合の `Apartment::Tenant.switch!` 配線の実装

## 証跡

### `Reports#inactive_users` EXPLAIN 比較（dev DB / docker MySQL 8.0）

実測 (`docker compose exec -T app bundle exec rails runner` で `ActiveRecord::Base.connection.execute("EXPLAIN ...")` を叩いて取得):

**Before（旧 NOT IN）:**

```
id | select_type        | table    | type           | possible_keys             | key                       | ref  | rows | Extra
 1 | PRIMARY            | users    | ALL            | nil                       | nil                       | nil  |   2  | Using where
 2 | DEPENDENT SUBQUERY | comments | index_subquery | index_comments_on_user_id | index_comments_on_user_id | func |   2  | Using where; Using index
```

- `DEPENDENT SUBQUERY` は外側 `users` の各行ごとにサブクエリを再評価する形。`comments.user_id` に NULL があると `NOT IN` 全体が NULL になり外側が空集合になる SQL 仕様の罠は EXPLAIN には出ない（実行結果でしか分からない）。

**After（LEFT JOIN ... IS NULL）:**

```
id | select_type | table    | type | possible_keys             | key                       | ref                       | rows | Extra
 1 | SIMPLE      | users    | ALL  | nil                       | nil                       | nil                       |   2  | Using temporary
 1 | SIMPLE      | comments | ref  | index_comments_on_user_id | index_comments_on_user_id | app_dev.users.id          |   1  | Using where; Not exists; Using index; Distinct
```

- `Not exists` 最適化が効いている: マッチが 1 件見つかった時点で comments 側のスキャンを打ち切る。
- `key = index_comments_on_user_id` で comments への結合は index のみ（`Using index`）。
- 外側 users は ALL のまま（テナント絞りなしの dev DB だと users 全件スキャン）。本番では `for_current_tenant` で `tenant_id` の WHERE が追加され、`index_users_on_tenant_id` に乗る想定。

### `posts` 複合インデックスの EXPLAIN

新規追加 `index_posts_on_tenant_id_and_created_at_and_id` がどう使われるかの実測:

**posts feed (tenant 絞り + created_at DESC + id DESC LIMIT 100):**

```
id | select_type | table | type | possible_keys                                                              | key                                              | ref   | rows | Extra
 1 | SIMPLE      | posts | ref  | index_posts_on_tenant_id, index_posts_on_tenant_id_and_created_at_and_id   | index_posts_on_tenant_id_and_created_at_and_id   | const |   1  | Backward index scan
```

- 複合 index が選ばれている (`key = index_posts_on_tenant_id_and_created_at_and_id`)。
- `Backward index scan` は MySQL 8.0 の機能で、`ORDER BY ... DESC` を逆方向に index 走査して `filesort` を回避する挙動。**これにより、 `WHERE tenant_id = ? ORDER BY created_at DESC, id DESC LIMIT N` が「インデックスのみで完結」する**（= 第4問のキーセットページネーションと整合）。

**posts daily group (DATE 関数を絡めた集計):**

```
id | select_type | table | type | possible_keys | key                       | ref   | rows | Extra
 1 | SIMPLE      | posts | ref  | (...3つ並ぶ)  | index_posts_on_tenant_id  | const |   1  | Using temporary
```

- `WHERE tenant_id = ?` で `tenant_id` 単独 index に乗るが、`GROUP BY DATE(created_at)` は関数 GROUP のため一時テーブル経由（`Using temporary`）。これは index で消せる種類のものではない（関数 index を別途張るかアプリ側で DATE 範囲に直すのが筋）が、第8問のスコープ外として明示する。

### クロステナント分離の振る舞い確認

`spec/models/tenant_isolation_spec.rb` に「Current.tenant を切替えると `for_current_tenant` が他テナントの行を返さない」「他テナントの `tenant_id` を明示渡しすると validation で弾かれる」「`Current.tenant` の id で `tenant_id` が自動補完される」ことを spec で固定化している。具体的な検証項目:

- `Post.for_current_tenant` がテナント A 文脈では A の post のみ、B 文脈では B の post のみを返す
- `User.for_current_tenant` も同様にテナント分離が効く
- `Post.create!(...)` で `tenant_id` が `Current.tenant.id` に自動的に埋まる
- `Post.new(tenant_id: 他テナント.id)` は `errors[:tenant_id]` 付きで invalid

これらが今後リグレッションで壊れた場合、spec が落ちる。

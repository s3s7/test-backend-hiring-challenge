# 第3問: モデルバリデーションとデータ整合性

## 再現（現象の確認）

### 症状 A: モデル側のバリデーション抜けと破損データの混入

第 2 問で追加した最小限の presence バリデーション（`User#name/email`, `Post#title/content`）以外は素通りで、以下のような不整合データが許される状態だった。

- `User#email` が形式不正（`"not-an-email"`）でも保存できる
- `User#password` が空でも保存できる
- `Comment#name` / `Comment#content` が空でも保存できる
- `Tenant#name` / `Tenant#subdomain` が空、または不正フォーマット（大文字・記号・先頭末尾ハイフン）でも保存できる
- DB スキーマも `NULL` 許可・unique index 無しで、アプリ側を回避すれば破損が永続化される

### 症状 B: email の照合順序（大小無視で別ユーザー化する）

```sql
-- 修正前の状態（unique 制約なし）で再現
INSERT INTO users (name, email, password, created_at, updated_at)
VALUES ('Admin1', 'admin@example.com', 'pw', NOW(), NOW());
INSERT INTO users (name, email, password, created_at, updated_at)
VALUES ('Admin2', 'Admin@example.com', 'pw', NOW(), NOW());

SELECT id, email FROM users WHERE LOWER(email) = 'admin@example.com';
-- => 2 rows
```

`utf8mb4_0900_ai_ci`（accent/case insensitive）の collation 配下では `=` 比較自体は大小無視で一致するのに、unique index が無いため**アプリの目には別ユーザーに見える**状態が成立する。ログイン処理が `WHERE email = ?` の collation に依存していると、どちらか一方しか引けない／両方引けるが順序未定義、といった**経路依存のバグ**になる。

### 症状 C: 並行下で `validates_uniqueness_of` だけでは重複が通る（TOCTOU）

`validates :email, uniqueness: { case_sensitive: false }` は、内部的に

```sql
SELECT 1 FROM users WHERE LOWER(email) = LOWER(?) LIMIT 1;  -- (check)
-- ... Ruby に戻ってバリデーション結果を判断 ...
INSERT INTO users (..., email, ...) VALUES (..., ?, ...);   -- (insert)
```

の **2 段 SQL** で実装されている。check と insert の間に **別プロセス／別リクエスト** が同じ email で INSERT を完了させると、両方の check は「未使用」を返し、両方の insert が通る。これは Time-Of-Check to Time-Of-Use（TOCTOU）レースの古典例。Rails のバリデーションは「同一プロセス内のメモリ整合」しか保証しないため、**DB の unique index でしか並行安全は得られない**。

## 原因

### A. 仕様（テスト）から validation が欠落しているだけ

`spec/models/{user,comment,tenant}_spec.rb` が前提とするバリデーションが `app/models` 側に実装されていなかった。第 2 問のスコープでは最小修正に留めていたため、本問で正式に追加する。

### B. unique 制約が DB レベルで存在しない

collation が大小無視であっても、unique index が無ければ重複行は物理的に書き込める。アプリ層の uniqueness バリデーションも次節 C の理由で並行下では破れる。

### C. ActiveRecord の uniqueness は SELECT → INSERT の 2 段で、間にロックが無い

`validates_uniqueness_of` は SQL の `SELECT 1 ... LIMIT 1` で存在チェックし、結果に応じて INSERT を発行する。`SELECT` は共有ロックも掛けないし、対象行が**まだ存在しない**ので gap lock も基本的には掛からない（`READ COMMITTED` / 通常 `REPEATABLE READ` の素の SELECT）。よって 2 つのトランザクションが「未使用」と判断 → 両方 INSERT 成功、というシナリオが成立する。

## 対応

### B-1. モデル側のバリデーション追加

| ファイル | 追加した validation |
| --- | --- |
| `app/models/user.rb` | `email`: presence / format（簡易 RFC）/ `uniqueness: { case_sensitive: false }`、`password`: presence、`before_validation` で email を `downcase.strip` で正規化 |
| `app/models/comment.rb` | `name`: presence、`content`: presence |
| `app/models/tenant.rb` | `name`: presence、`subdomain`: presence / format（RFC 1123 風 subdomain）/ `uniqueness: { case_sensitive: false }` |

`User#password=` は「空文字を渡されたら暗号化を通さず生のまま保存する」ようにしている。これは `encrypt_and_sign("")` を呼ぶと **非空の暗号化文字列が入って presence バリデーションが誤って通る**ため。テストもこの挙動を固定している。

### B-2. DB 制約のマイグレーション

`db/migrate/20260611100000_enforce_data_integrity.rb` で 3 段階に分けた。

1. **データ修復**（`DataFixer.run!`）— 既存の破損行を消す／統合する。これを先にやらないと NOT NULL / unique 制約が違反で貼れない。
2. **NOT NULL 化** — `users.{name,email,password}`, `posts.{title,content}`, `comments.{name,content}`, `tenants.subdomain` を `null: false` に。
3. **unique index** — `users.email`, `tenants.subdomain` に unique index を追加。column collation が `utf8mb4_0900_ai_ci` のため、`Admin@example.com` と `admin@example.com` は **DB レベルで重複として弾かれる**（症状 B の根治）。

> 「修復 → 制約」を migration 1 本に閉じ込めたのは、**rake を打ち忘れた deploy** でも制約付与が必ず成功させるため。`DataFixer` は冪等なので 2 回呼ばれても安全。

### B-3. `rake app:fix_data` と `DataFixer` の共有

`lib/data_fixer.rb` を single source として、migration と rake から両方呼べる構成にした。`lib/` は autoload 対象外なので、両側で `require Rails.root.join("lib/data_fixer.rb")` を明示している（migration で autoload に頼ると `db:migrate` 単体実行で落ちうる）。

修復内容（冪等・WHERE で対象 0 件なら no-op）:

- `users.email` を `LOWER()` に正規化（1 本 SQL）
- 大小無視で同一 email の重複ユーザーを 1 行に統合
  - survivor 選定: **valid な行（name/password が空でない）を最古より優先** → 直後の `purge_invalid_users` で survivor が消えるのを防ぐ
  - 関連 posts/comments を survivor に **付け替えてから** 重複 user を delete（逆順だと孤児が出る）
- name/email/password 欠損の user を関連ごと排除（posts は NOT NULL FK ゆえ delete、comments は user_id を NULL に）
- title/content 欠損の post とその comments を delete
- name/content 欠損の comment を delete
- 同一 subdomain の tenant を最古残しで dedup
- name/subdomain 欠損の tenant を delete

### B-4. テスト

| ファイル | 追加した観点 |
| --- | --- |
| `spec/models/user_spec.rb` | email format / 正規化（trim + downcase）/ 大小無視の一意性 / password の presence（nil と空文字の両方）/ `#authenticate` |
| `spec/models/comment_spec.rb` | name / content の presence、user optional |
| `spec/models/tenant_spec.rb` | name / subdomain presence、subdomain format（大文字・記号・先頭末尾ハイフン）、大小無視の一意性 |
| `spec/lib/data_fixer_spec.rb` | 重複 email 統合（最古残し）／ valid 優先の survivor 選定／ 冪等性／ クリーン DB に対する no-op／ email 正規化 |

`spec/lib/data_fixer_spec.rb` だけ DDL を `before(:all)/after(:all)` に置いている。**transactional fixtures が開いている SAVEPOINT を MySQL の DDL auto-commit が破壊**する制約があり、`before(:each)` で `remove_index` するとその後の SQL が `SAVEPOINT active_record_1 does not exist` で吹き飛ぶため。

## 判断・トレードオフ

### 「修復 → 制約」を 1 本の migration にまとめた理由（vs 別 migration 2 本案）

- 採用案: migration 内で `DataFixer.run!` → 制約付与
- 却下案: 修復 migration と制約 migration を分ける

分けると「修復 migration だけ走って制約 migration が止まる」「逆に修復前に制約を貼ろうとして失敗する」状態が運用上ありうる。1 本にしておけば **atomic に「修復後に制約が貼られた状態」へ遷移**でき、失敗時は全体 rollback で元に戻る（DataFixer の destroy は不可逆だが、それは down では復元しない方針を migration コメントに明記）。

### `User#password=` で空文字を暗号化しない選択

`ActiveSupport::MessageEncryptor#encrypt_and_sign("")` は空文字でも IV/タグ込みの非空文字列を返す。素直に呼ぶと「`presence` バリデーションが効かなくなる」ため、`blank?` のときだけ `super(password)`（生のまま）に分岐させた。テスト（`'password が空なら invalid'`, `'password が nil なら invalid'`）でこの挙動を固定している。

### 一意性ポリシー: 「大小無視」を採用、「厳密一致」を却下した理由

要件で「大小無視で一意／厳密一致のいずれか」を選ぶよう求められている。採用したのは **大小無視**。

- ユーザー目線では `Admin@example.com` と `admin@example.com` を別アカウントにできる UX は事故の温床（パスワードリセット先が分岐する、SSO で名寄せできない、サポート対応で本人特定がブレる）
- collation が既に `utf8mb4_0900_ai_ci` なので、unique index と組み合わせると **DB レベルで「同じ email」と判定** → 厳密一致を採用する場合は column collation を `_bin` に変える追加変更が必要で、無駄な変更を増やす

### 鍵となる validation を「アプリ + DB」の二重で持つ意義

アプリ層の `validates :email, uniqueness:` は便利な UX（フォーム上で「使われています」を即返せる）を提供するが、TOCTOU で破れる。DB の unique index は遅いがレースに耐える。**両方を持つ**ことで、

- 通常運用ではアプリ層がフレンドリーなエラーを返す
- 並行下のレースは DB の `RecordNotUnique` でラスト・ライン・ディフェンスする

という棲み分けにしている。今回 `User#email` / `Tenant#subdomain` に対する `RecordNotUnique` のハンドリング実装まではスコープに入れていない（要件 6 の「余裕があれば」部分）。理由は (a) この問題のスコープが整合性の "確立" にあり (b) controller 側の API 設計（第 4 問）と一緒に扱うほうが整合的だから。

### スコープを広げなかった範囲

- **TOCTOU ハンドリングの実装** — 上記理由で「説明まで」（要件の最低ライン）。`save` を `rescue ActiveRecord::RecordNotUnique` で受けて errors に詰め直す pattern は典型実装としては自明で、必要になった時点で controller 層に入れる。
- **`User#password` のハッシュ化方式** — 現状の `MessageEncryptor` は復号可能（双方向）で、本来は `has_secure_password` + bcrypt が望ましい。が、これは「バリデーション」のスコープを超える設計変更なので本問では触らず、`#authenticate` の挙動だけテストで固定して契約を守った。
- **posts への validation 追加** — 第 2 問で `title/content` の presence を入れ済み。本問の migration では NOT NULL 化と整合性データ修復で固める。

## 証跡

### 修正後 spec の通過

```
$ docker compose exec app bundle exec rspec \
    spec/models/user_spec.rb \
    spec/models/comment_spec.rb \
    spec/models/tenant_spec.rb \
    spec/lib/data_fixer_spec.rb
# => 全 example 0 failures
```

### email 大小無視ユニーク制約の DB レベル確認

```
mysql> INSERT INTO users (name, email, password, created_at, updated_at)
       VALUES ('A', 'admin@example.com', 'pw', NOW(), NOW());
Query OK, 1 row affected

mysql> INSERT INTO users (name, email, password, created_at, updated_at)
       VALUES ('B', 'Admin@example.com', 'pw', NOW(), NOW());
ERROR 1062 (23000): Duplicate entry 'Admin@example.com' for key 'users.index_users_on_email_unique'
```

### `rake app:fix_data` 冪等性

```
$ docker compose exec app bin/rails app:fix_data
[DataFixer] normalize_user_emails: N rows lowercased
[DataFixer] consolidate_duplicate_users: M groups merged
...

$ docker compose exec app bin/rails app:fix_data
# => 2 回目はログ出力なし（全 step が WHERE で 0 件 → no-op）
```

# 第6問: サービス層へのリファクタリング

## 再現（現象の確認）

`PostsController` の `feed` / `export` / `publish` にコントローラ責務外のロジックがべったり書かれている。

- `feed`: 一覧取得 → 文字列正規化 (`normalize`) → ハッシュ整形までを controller の中で実施
- `export`: 一覧取得 → 各行を `[...].join(",")` で組み立て → 全体を `\n` で連結
- `publish`: `Post.transaction` で post / 関連 comments を順序ロック → `published = true`

`normalize` は controller の private メソッドとして残っており、テストするには controller を request spec から動かすしかない（純粋なハッシュ生成のロジック単体での検証が困難）。`publish` のトランザクション境界やロック順序は controller を介さないと再現できないため、ユニット単位の検証もしづらい。「テストしづらく可読性が低い」という背景がそのまま現状の姿として現れていた。

## 原因

- HTTP の受け渡し（params の解釈・status・redirect / render）と業務ロジック（取得・加工・トランザクション境界）が同じメソッド内に同居している。
- `normalize` のような副作用なしの純粋関数まで controller の private に閉じているため、再利用も単体テストもできない。
- `publish` の「親→子の順にロック」というドメイン知識が controller に書かれていて、外から（例えば Sidekiq から）同じ手順で publish したくなった時にコピペになる。

## 対応

`app/services/posts/` 配下に Plain Old Ruby Object として 3 つのサービスを切り出した。いずれも `initialize` で外部依存（ActiveRecord の `scope` や対象 `post`）を受け取り、`call` を 1 つだけ公開する形に統一。

| サービス | 元の場所 | 責務 |
|---|---|---|
| `Posts::FeedQuery` | `PostsController#feed` | `Post.includes(:user, :comments).limit(n)` の取得と、`normalize` を含む JSON 用ハッシュ整形 |
| `Posts::Exporter` | `PostsController#export` | 全件の eager load と、`[id, title, content, author, comment_count].join(",")` を `\n` で連結した CSV 文字列の生成 |
| `Posts::Publisher` | `PostsController#publish` | `Post.transaction` 内で post → 子コメント (id 昇順) の順にロックを取り `published = true` |

`PostsController` 側は HTTP の受け渡しとシリアライズのみ:



`normalize` は feed 専用なので `Posts::FeedQuery` の private に移動して controller から削除。

### テスト

- ユニット (`spec/services/posts/*_spec.rb`)
  - `FeedQuery`: scope/limit の差し替えで件数が変わる、normalize が連続空白を 1 つに詰める、`scope: Post.none` で空配列になることを確認（要件2「外部依存はモック/スタブ化」を `scope` 差し替えで担保）
  - `Exporter`: 1 行 / 複数行 / 空 scope の 3 ケースで戻り値文字列が既存挙動と一致
  - `Publisher`: `lock!` の呼び出し順（post → 子コメント id 昇順 → `update!`）を double 越しに記録して検証、例外時に published がロールバックされること
- 統合 (`spec/requests/posts_spec.rb`)
  - feed / export / publish の HTTP レスポンス（status / Content-Type / ボディ）が既存挙動と一致することを確認（要件4）

## 判断・トレードオフ

### スコープの限定: `feed` / `export` / `publish` のみ

要件5 で対象が明示されていたので `show` の views_count 増分や `create` / `update` の AR.create には触れていない。

- `show` の `@post.update(views_count: @post.views_count + 1)` は競合下で値が壊れる古典的バグ（インクリメントが atomic でない）だが、修正すると挙動が変わる（同時更新で異なる値になる）。第13問あたりの並行性スコープに寄せた方が筋が良い。
- `create` の `User.create(params[:user])` も mass assignment / strong parameters のスコープで別問。

「テストしづらいから直す」という今回の趣旨を踏まえて、業務ロジックの体積が大きい 3 つに限定。

### サービスの形式: PORO (`initialize` + `call` 1 つ)

`ActiveModel::Model` を継承する案、`Interactor` gem を入れる案、`Result` 型を返す案などを検討したが、

- 3 サービスとも依存しているのは ActiveRecord だけで、フォーム的なバリデーション層は要らない → `ActiveModel::Model` は過剰
- 失敗時の戻り値分岐が必要なのは Publisher だけ、かつ例外を `Post.transaction` がロールバックしてくれるので、Result 型より素直に例外を上げる方が読める
- gem 導入は責務分離という目的に対して依存追加が見合わない

ので素の Ruby クラスに統一。`new(...).call` という最小契約だけ揃えた。

### `Exporter` を `CSV` gem に切り替えなかった

元実装は `[...].join(",")` で書かれており、タイトルや本文に `,` や改行が含まれると壊れる。`CSV.generate` を使えば堅牢化できるが、

- 出力バイト列が変わる（クォート挿入や末尾の改行）→ 要件4「API の挙動が変わらないことを統合テストで確認」に違反
- 「リファクタ」の趣旨は責務分離であって出力仕様の改善ではない

ため、互換最優先で `join(",")` をそのまま `Exporter#call` の内側に移植。エスケープ対応は別 PR に切る方が変更の意図が分かりやすい。

### Publisher の単体テストで double を使った理由

ActiveRecord 越しの `lock!` は実 DB が無いと走らないが、テストの主眼は「呼び出し順序が post → 子コメント id 昇順 → update! であること」であって DB ロックの有無ではない。順序は `allow(...).to receive` で記録すれば DB を介さず検証できる。要件2「外部依存はモック/スタブ化」をそのまま実装した形。

なお「実際に DB ロックが取れているか」は spec の範囲外（並行制御の検証は第13問の責務）。

### スコープ外として明示

- `show#views_count` 並行更新バグの修正（第13問へ）
- `create` / `update` の mass assignment 対応（別問）
- Exporter の CSV エスケープ対応（要件4 違反になるため別 PR）

## 証跡

該当なし。

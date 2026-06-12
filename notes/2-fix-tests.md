# 第2問: テストの全通

## 再現（現象の確認）

`bundle exec rspec` を実行すると 3 つの異なる症状を確認した。

### 症状 A: rspec 自体が起動しない（全 example が NoMethodError）

**再現コマンド:**
```sh
docker compose exec app bundle exec rspec
```

**観測:**
```
NoMethodError:
  undefined method `fixture_path=' for an instance of RSpec::Core::Configuration
  # ./spec/rails_helper.rb:15:in 'block in <main>'
```
seed/順序に依存せず、全 example が collection 段階で吹き飛ぶ。

### 症状 B: モデル validation 系 4 example が常に失敗

`rails_helper.rb` を直したあと露見した、確定的に落ちる失敗群。

**再現コマンド:**
```sh
docker compose exec app bundle exec rspec spec/models/post_spec.rb spec/models/user_spec.rb
```

**落ちる example（順序・seed 非依存で必ず再現）:**
- `Post タイトルなしでは無効`（`post_spec.rb:9`）→ `expected #<Post ...> to be invalid`
- `Post コンテンツなしでは無効`（`post_spec.rb:14`）
- `User 名前なしでは無効`（`user_spec.rb:4`）
- `User メールなしでは無効`（`user_spec.rb:9`）

### 症状 C: `post_counter_spec.rb` が確率的に落ちる（フレーキー）

**初回（クリーン DB）の動き:** seed に関係なく 3 example とも通る。

**再現コマンド（クリーンな test DB から開始）:**
```sh
docker compose exec app bin/rails db:test:prepare
# 同じコマンドを何度か繰り返す
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  docker compose exec app bundle exec rspec spec/models/post_counter_spec.rb
done
```

**観測される失敗（例: 8 回目あたりで初出）:**
```
Failures:
  1) Post keeps a single account per author email
     Failure/Error: expect(User.where(email: @author.email).count).to eq(1)
       expected: 1
            got: 2  # 実行回数が増えると 3, 4 ... と単調増加
     # ./spec/models/post_counter_spec.rb:14
```

**順序・seed の関与:**
- 失敗は `rspec --seed N` の N に依存しない。
- 1 回の rspec 実行内では 3 example の実行順を変えても結果は同じ（`before(:all)` で 1 回しか走らないため）。
- **再現を支配しているのは「これまで何回 rspec を回したか」と「DB に残った User 行数」のみ**。

**衝突確率（誕生日の問題、`rand(100)` の場合）:**
| 累積実行回数 N | 少なくとも 1 回衝突する確率 |
| --- | --- |
| 5 | 約 9.7% |
| 10 | 約 37% |
| 12 | 約 49% |
| 20 | 約 87% |
| 30 | 約 99% |

→ ローカルで 50 回連続実行すれば、ほぼ確実に途中で落ちる挙動が観測できる。

## 原因

### A. `fixture_path=` の API 廃止

rspec-rails 7.0 で単数形 setter `fixture_path=` が削除され、`fixture_paths=`（配列を受け取る複数形）に統一された。`Gemfile` の `rspec-rails "~> 8.0"` と `rails_helper.rb` の旧 API がミスマッチ。

### B. モデル側のバリデーション欠落

`spec/models/post_spec.rb` と `spec/models/user_spec.rb` は `title` / `content` / `name` / `email` に対する presence バリデーションの存在を前提に書かれているが、`app/models/post.rb` / `app/models/user.rb` には `belongs_to` / `has_many` のみで `validates` が一つも定義されていなかった。実装が仕様（テスト）から欠落しているだけ。

### C. `before(:all)` × `rand(100)` の二重欠陥

落ちているのは「同じ email の User が 1 件しか存在しないこと」を確認する example で、表面の症状は「過去の実行で作った User が DB に残っている」。これを生む原因は 2 つ重なっている。

1. **`before(:all)` はトランザクション境界の外**  
   `rails_helper.rb` の `config.use_transactional_fixtures = true` は **各 example** を `BEGIN` / `ROLLBACK` で包む仕組みで、`before(:all)` の中で行った `User.create!` は包まれない。rspec が終わっても User 行が test DB に残り続ける。

2. **`rand(100)` の鍵空間が狭すぎる**  
   email のサフィックスが 100 通りしかないため、累積実行回数が増えるほど衝突確率が誕生日の問題で急増する（上表）。仮に `before(:all)` を直しても、別の spec で同 email を作れば衝突しうるという脆弱性が残る。

→ 「永続化リーク」と「鍵空間不足」が掛け算で表面化したのが今回のフレーキー。

## 対応

| 症状 | 変更ファイル | 修正内容 |
| --- | --- | --- |
| A | `application/spec/rails_helper.rb` | `config.fixture_path = "..."` → `config.fixture_paths = ["..."]`（配列に変更） |
| B | `application/app/models/post.rb` | `validates :title, presence: true` / `validates :content, presence: true` を追加 |
| B | `application/app/models/user.rb` | `validates :name, presence: true` / `validates :email, presence: true` を追加 |
| C-1 | `application/spec/models/post_counter_spec.rb` | `before(:all) do ... end` → `before do ... end`（各 example 内で `BEGIN`/`ROLLBACK` 対象に） |
| C-2 | `application/spec/models/post_counter_spec.rb` | `email: "author-#{rand(100)}@example.com"` → `email: "author-#{SecureRandom.hex(8)}@example.com"`（鍵空間 100 → 2^64） |

仕様の意図（「同じ email の User が 1 件しか存在しない」を確認する）は変えていない。

## 判断・トレードオフ

### C-1 を `before(:all)` のまま残す案を却下した理由

`before(:all)` を維持しつつ `after(:all)` で明示的に `@author.destroy` を書けば DB は綺麗に保てる。だが
- 例外が発生したら clean-up がスキップされる
- spec が増えた時に teardown を忘れる人的事故が起きやすい  
ため、Rails 標準の transactional fixtures に乗る `before do ... end` を採用した。「テスト間で 1 回だけ初期化したい」という意図そのものが今回の spec には不要（3 example 全てが author を再利用しているだけで、生成コストは無視できる）。

### C-2 で Faker を使わず `SecureRandom.hex(8)` を選んだ理由

候補は 3 つあった。

| 案 | 鍵空間 | 採否 |
| --- | --- | --- |
| `Faker::Internet.unique.email` | プロセス内で状態管理 | **不採用** |
| `Faker::Internet.email` | ランダムだが衝突可 | **不採用** |
| `SecureRandom.hex(8)` で suffix を生成 | 2^64 | **採用** |

`Faker.unique` は **プロセス内**でしか追跡しないため、test DB のリーク（症状 C の本丸）と組み合わさると結局衝突しうる。`SecureRandom` は無状態で 2^64 の鍵空間、追加 gem 依存も無い。fixture/factory_bot に乗らない “その場限りの一意 email” に対しては最もシンプル。

### スコープを広げなかった範囲

- `User.email` に DB ユニーク制約や `validates :email, uniqueness: true` を入れるのは本問のスコープ外（モデル仕様の追加になる）。今回は「テスト側の作り方を直す」までに留めた。
- `factory_bot` の sequence を導入して spec 全体の User 生成を統一する案も見送り。第 2 問の最小修正からは逸脱する。

## 証跡

### 修正前: 連続実行で再現

```
$ for i in $(seq 1 20); do
    docker compose exec app bundle exec rspec spec/models/post_counter_spec.rb \
      | grep -E "(examples|Failure)"
  done
# ... 数回目までは "3 examples, 0 failures"
# ... 10 回目前後で "3 examples, 1 failure"（keeps a single account per author email）
```

### 修正後: 50 回 `--order rand` で安定確認

```
$ for i in $(seq 1 50); do
    docker compose exec app bundle exec rspec --order rand 2>&1 \
      | tail -1
  done
# 50/50 すべて: "N examples, 0 failures"
```

`bin/rails db:test:prepare` でクリーンに戻した上での結果ではなく、**前回実行で残った User 行ごと**の状態で 50 回連続パスしている → 永続化リーク自体が解消されていることの裏付け。

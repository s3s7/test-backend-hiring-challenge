# 第1問：開発環境の構築

## セットアップ手順

```bash
# 1. リポジトリをクローン
git clone <your-repo-url>
cd <repo>/application

# 2. イメージをビルド
docker compose build

# 3. コンテナを起動（app / db / redis / sidekiq）
docker compose up -d

# 4. DB作成・マイグレーション・シードデータ投入
docker compose exec app bin/rails db:create db:migrate db:seed

# 5. アプリ確認
open http://localhost:3000

# 6. テスト実行
docker compose exec app bundle exec rspec

# 7. 静的解析
docker compose exec app bundle exec rubocop
docker compose exec app bundle exec reek
```

## 再現（現象の確認）

配布時点の開発環境で、以下を確認した。

- **Dockerfile**：単一ステージ構成。`build-essential` 等のビルドツールと `vim` / `nodejs` / `npm` が最終イメージに同梱され、`root` でアプリが起動する。`COPY . .` がGemfileより先にあるため、アプリコードを1行変えるだけで `bundle install` のキャッシュが無効化される。`HEALTHCHECK` 未定義。
- **`.dockerignore` 不在**：`log/`、`tmp/`、`.git/` がビルドコンテキストに含まれ、イメージに混入。
- **`compose.yml`**：`redis` / `sidekiq` が未定義のため、Sidekiqを使う後続の問題に着手できない。`depends_on` が「コンテナが起動したか」しか見ておらず、DBの接続受付前に `app` が起動して接続エラーになり得る。
- **Gemfile**：RSpec / FactoryBot / RuboCop / Reek 等のテスト・静的解析gemが入っておらず、テストもLintも走らせられない。
- **エディタ設定**：`.vscode/` 不在。Ruby LSPやRuboCop連携が個人環境依存になり、フォーマッタ差分が混入しやすい。

## 原因

- **イメージ肥大化と攻撃面拡大**：単一ステージ＋root実行＋不要パッケージの組み合わせ。ビルド時にしか要らないツールチェインが本番（および開発）イメージに残り続ける構造になっている。
- **ビルド遅延**：`COPY . .` が `bundle install` より前にあるため、Dockerのレイヤーキャッシュ仕様上、アプリコード変更で必ず gem 解決から再実行される。
- **起動順序のレース**：`depends_on` のデフォルト挙動は「依存先コンテナが**起動**したら次へ」であり「依存先が**接続を受け付ける状態**」は保証しない。MySQLは初期化に時間がかかるため、アプリ側が先に `db:migrate` を叩いて失敗する余地がある。
- **ジョブ基盤の前提が満たされない**：本課題は後続でSidekiqを扱うが、Redisとworkerコンテナがそもそも `compose.yml` にない。
- **品質ゲート不在**：テスト・Lint・コードスメル検出のいずれも実行手段がなく、変更の妥当性をローカルで担保できない。

## 対応

### `Dockerfile`：マルチステージ化と非rootユーザー

- `builder` → `development` の2ステージ構成。`builder` で native extension をコンパイルし、最終ステージにはコンパイル済み gem だけをコピー。`build-essential` / `libmysqlclient-dev` は最終イメージに残らない。
- `uid=1000` の `app` ユーザーを作成し、`USER app` で非root実行。
- レイヤー順を `Gemfile`/`Gemfile.lock` COPY → `bundle install` → アプリコード COPY に変更。アプリコードだけの変更で `bundle install` レイヤーを再利用できる。
- `HEALTHCHECK` を Rails 7.1+ デフォルトの `/up` で実装。`--start-period=60s` で初期化時間を吸収。

### `.dockerignore` 新規

`log/`、`tmp/`、`.git/`、`spec/` を除外。

### `compose.yml`：依存サービスとヘルスチェック

- `redis` / `sidekiq` サービス追加（後続問題で必要）。
- `db` / `redis` に `healthcheck`（`mysqladmin ping` / `redis-cli ping`）を追加し、`depends_on` に `condition: service_healthy` を指定。「接続可能」になるまで `app` の起動を遅延させる。
- `bundle_cache` 名前付きボリュームで gem を永続化。
- `restart: unless-stopped` で異常終了時の自動復帰。

### `Gemfile`：テスト・Lint環境

| 追加 gem | 群 | 役割 |
|---|---|---|
| `rspec-rails ~> 8.0` | development, test | Rails 8系対応のRSpec |
| `factory_bot_rails` | development, test | テストデータ生成 |
| `faker` | development, test | ダミー値生成 |
| `rubocop` / `rubocop-rails-omakase` / `rubocop-rspec` | development | 静的解析（omakaseベース） |
| `reek` | development | コードスメル検出 |

全て `require: false` を付与し、Rails起動時の自動requireを避ける。

### `.rubocop.yml`：omakase継承のみ

`inherit_gem: rubocop-rails-omakase: rubocop.yml` を入れ、自前ルールは `AllCops` の除外対象（`db/schema.rb` 等の自動生成ファイル）のみ。

### `.vscode/settings.json` / `.vscode/extensions.json`

- `rubyLsp.formatter: "rubocop"` / `rubyLsp.linters: ["rubocop"]` でBundler経由のRuboCopを使用。
- `rubyLsp.bundleGemfile: "application/Gemfile"` でGemfile位置を明示。
- 推奨拡張は `extensions.json` の `recommendations` に分離。

## 判断・トレードオフ

- **マルチステージのターゲットは `development` のみ採用**：本課題のスコープは開発環境構築なので、`production` ステージは作らなかった。本番投入時は `RAILS_ENV=production` / `bundle config --without development test` / assets precompile を持つ別ステージが必要だが、今やると未使用のコードが残り保守負債になる。
- **RuboCopは `rails-omakase` を採用**：自前で `.rubocop.yml` を組むと、ルールの妥当性議論にレビュー時間を取られやすい。Basecamp/37signalsの実運用に基づく既製ルールに乗ることで、ルール選定の判断を委譲してアプリ実装に時間を使う方針。代替として `standard` も検討したが、Rails特化ルール（`rubocop-rails`）が同梱される omakase の方が今回の用途に合う。
- **`depends_on` を `condition: service_healthy` にした理由**：起動時に `bin/rails db:create` がDB接続失敗で落ちる現象を避けるため。`bin/wait-for-it` 等の起動スクリプト方式も検討したが、Compose標準機能で完結する方が依存が減る。
- **`bundle_cache` を名前付きボリュームに**：bind mount 案もあるが、ホストOS（macOS）でのI/O性能差を避けるため named volume を選択。
- **未深掘り**：
  - **イメージサイズ・ビルド時間の前後比較は未計測**。本来は `docker images` / `docker build --progress=plain` の時間ログを残すべきだが、配布時点のイメージとの比較を取るには元のDockerfileに戻してビルドし直す手間があり、第2問以降の作業時間を優先して見送った。
  - **`production` ステージ**：上記の通り未作成。

## 証跡

- 計測値（イメージサイズ・ビルド時間の前後比較）は未取得。CI上で `docker build` 時間が計測できるようになった段階で追記予定。
- 起動確認：`docker compose up -d` 後、`docker compose ps` で全サービスが `healthy` 表示になること、`curl -f http://localhost:3000/up` が 200 を返すことを目視確認。

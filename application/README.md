# Awesome Night Blog（試験のベースアプリ）

ナイトテーマのブログアプリです。Bootstrapを採用し、Railsで構築されています。
本アプリは技術試験の題材で、**意図的なバグ・未実装・アンチパターン**を含みます。各課題は本リポジトリの`docs/`を参照してください。

## 起動手順

Docker Composeで動作します。下記でアプリとDBを起動し、DB作成・マイグレーション・シード投入を実行してください。

```bash
docker compose up --build -d
docker compose exec app bin/rails db:create
docker compose exec app bin/rails db:migrate
docker compose exec app bin/rails db:seed
```

- アプリ: http://localhost:3000
- コンテナーに入る: `docker compose exec app bash`

## 開発環境

- Ruby 3.4.x
- Rails 8.1.x
- MySQL 8.0
- Docker & Docker Compose

> テスト・Lint（RSpec / RuboCopなど）の導入は第1問の課題です。導入後の実行コマンドは各自の構成に合わせて `notes/1-setup.md` または当 `README.md` に追記してください。

# =============================================================================
# Stage 1: builder
#   目的: gem のコンパイル（native extension含む）を行う。
#   build-essential / libmysqlclient-dev はコンパイル時だけ必要で
#   最終イメージには不要のため、このステージにのみ置く。
# =============================================================================
FROM ruby:3.4.8-slim AS builder

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      default-libmysqlclient-dev \
      git \
      curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Gemfile/Gemfile.lock だけを先にコピー。
# アプリコードより先にコピーすることで、コードを変更しても
# Gemfile が変わらない限り bundle install のキャッシュが有効になる。
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4 --retry 3

# =============================================================================
# Stage 2: development（最終イメージ）
#   目的: アプリの実行に必要なものだけを含む slim なイメージ。
#   builder からコンパイル済みの gems のみをコピーし、
#   ビルドツールは含めない。
# =============================================================================
FROM ruby:3.4.8-slim AS development

# 実行時に必要な最小限のパッケージのみインストール。
# mysql-client: db:migrate 等で使用。
# curl: HEALTHCHECK に使用。
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      default-mysql-client \
      curl && \
    rm -rf /var/lib/apt/lists/*

# 非 root ユーザーを作成。
# root でコンテナを動かすと、コンテナ侵害時にホストへの影響が大きい。
RUN groupadd --gid 1000 app && \
    useradd --uid 1000 --gid 1000 --no-create-home app

WORKDIR /app

# builder ステージでコンパイル済みの gems をコピー（アプリコードはコピーしない）。
# 開発時は compose.yml のボリュームマウントでコードを反映する。
COPY --from=builder /usr/local/bundle /usr/local/bundle

# アプリコードをコピーし、所有者を app ユーザーに設定。
COPY --chown=app:app . .

# ログ・一時ファイル用ディレクトリを作成し、書き込み権限を付与。
RUN mkdir -p log tmp/pids && chown -R app:app log tmp

USER app

EXPOSE 3000

# /up は Rails 7.1+ のデフォルトヘルスチェックエンドポイント。
# --start-period=60s: 起動完了を待つ猶予時間（DB接続・migration時間を考慮）。
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
  CMD curl -f http://localhost:3000/up || exit 1

CMD ["bin/dev"]

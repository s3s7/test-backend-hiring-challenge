# frozen_string_literal: true

# 第7問: Sidekiq の Redis 接続と Dead Set の挙動を明示。
# - Sidekiq の標準動作: ジョブが最大リトライ回数を超えると Dead Set へ移送
# - Dead Set の保持上限を 1000 件 / 180 日に設定（既定は 10000 件 / 180 日）
# - retry 回数 25 はジョブ側の `retry_on` 宣言と二重管理になりやすいので、
#   ジョブ単体の `retry_on` を真実の定義として扱う方針
#   （Sidekiq 全体の上限はあくまでセーフティネット）

redis_url = ENV.fetch("REDIS_URL", "redis://redis:6379/0")

Sidekiq.configure_server do |config|
  config.redis = { url: redis_url }

  # Dead Set 保持期間と件数の上限（メモリ無制限増加を避ける）
  config[:dead_max_jobs] = 1_000
  config[:dead_timeout_in_seconds] = 180 * 24 * 60 * 60 # 180 days
end

Sidekiq.configure_client do |config|
  config.redis = { url: redis_url }
end

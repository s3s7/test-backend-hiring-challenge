# frozen_string_literal: true

# 第7問: コメント通知ジョブ。
# - at-least-once 配送（再実行で副作用が複数回起こり得る）を前提に、
#   CommentNotification(comment_id UNIQUE) への挿入を冪等性ガードとして使う
# - リトライポリシーは ActiveJob の retry_on で宣言（attempts/wait をジョブ単体に閉じる）
# - 5 回失敗で Sidekiq の Dead Set に自動移送。Rails.logger.error も併発する
class CommentNotificationJob < ApplicationJob
  queue_as :default

  # 再実行ポリシー（要件1）。指数的に待つことで一時障害を吸収する。
  retry_on StandardError,
           attempts: 5,
           wait: :polynomially_longer

  # 削除済 Comment を ActiveJob が deserialize できずに永久リトライするのを防ぐ（要件1, 2）。
  discard_on ActiveJob::DeserializationError do |job, error|
    Rails.logger.error("[CommentNotificationJob] discarded: #{error.class} args=#{job.arguments.inspect}")
  end

  def perform(comment_id)
    # 冪等性ガード（要件5）。
    # at-least-once 配送で同じ comment_id が複数回到来しても、UNIQUE 違反で 2 度目以降は短絡 return する。
    # トランザクション内で counter 加算とセットで実行することで、
    # 「ガード行は入ったが加算で例外 → ロールバック → 次回の再実行で同じ comment_id が再投入されたら、
    #   ガード行も加算もまだ無いので両方やり直せる」を成立させる。
    ApplicationRecord.transaction do
      CommentNotification.create!(comment_id: comment_id)
      comment = Comment.find(comment_id)
      Post.where(id: comment.post_id).update_all("notifications_count = notifications_count + 1")
      Rails.logger.info("[CommentNotificationJob] notified post=#{comment.post_id} comment=#{comment_id}")
    end
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
    # UNIQUE 違反 = 既に通知済み。リトライ不要なので例外を握り潰す。
    # ActiveRecord::RecordInvalid は uniqueness validation 経由でも同じ意味で発生する。
    Rails.logger.info(
      "[CommentNotificationJob] already notified, skipped (comment=#{comment_id}, #{e.class})"
    )
  end
end

# frozen_string_literal: true

# 第7問: 通知ジョブの冪等性ガード。
# CommentNotificationJob が同じ comment_id で複数回実行されても、
# DB レベルの UNIQUE 制約により副作用 (notifications_count の加算) は 1 回に収まる。
class CommentNotification < ApplicationRecord
  belongs_to :comment

  validates :comment_id, uniqueness: true
end

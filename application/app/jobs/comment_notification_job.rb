class CommentNotificationJob < ApplicationJob
  queue_as :default

  def perform(comment_id)
    comment = Comment.find(comment_id)
    post = comment.post
    post.update(notifications_count: post.notifications_count + 1)
    Rails.logger.info("Notified author of post #{post.id} about comment #{comment.id}")
  end
end

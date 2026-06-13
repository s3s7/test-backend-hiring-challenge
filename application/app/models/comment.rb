class Comment < ApplicationRecord
  belongs_to :post
  belongs_to :user, optional: true

  validates :name, presence: true
  validates :content, presence: true

  # 第7問: トランザクショナル投入（要件6）。
  # 旧実装は CommentsController#create で save 直後に perform_later を呼んでいたため、
  # 「保存はコミット済みなのに enqueue が失敗」「enqueue 後にトランザクションが
  # ロールバックして enqueue だけが残る」といった dual-write 不整合が起こり得た。
  # after_commit on: :create に置くことで、DB に確定した直後のみ enqueue する。
  after_commit on: :create do
    CommentNotificationJob.perform_later(id)
  end
end

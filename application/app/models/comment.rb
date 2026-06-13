class Comment < ApplicationRecord
  include TenantScoped

  # 第9問: /posts/feed の低レイヤキャッシュは Post.cache_key_with_version
  # （= scope の max(updated_at) と count を集約したキー）で無効化する。
  # touch: true で Comment の create/destroy が Post.updated_at を bump し、
  # comment_count が変わる時に feed キャッシュが自動的に作り直される。
  belongs_to :post, touch: true
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

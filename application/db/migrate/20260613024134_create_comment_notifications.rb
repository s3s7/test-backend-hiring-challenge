# 第7問: ジョブ冪等化のための processed-set 兼ジャーナルテーブル。
# CommentNotificationJob は (comment_id) UNIQUE への insert を最初に行い、
# 違反したら「既に通知済み」と判断して短絡 return する。
# これにより at-least-once 配送下でも副作用が 1 回に収束する。
class CreateCommentNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :comment_notifications do |t|
      t.references :comment, null: false, foreign_key: { on_delete: :cascade }, index: false

      t.timestamps
    end

    # 冪等性の本体: comment_id ごとに 1 行までしか入れない。
    add_index :comment_notifications,
              :comment_id,
              unique: true,
              name: "index_comment_notifications_on_comment_id_unique"
  end
end

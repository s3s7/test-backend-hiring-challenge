# キーセットページネーション（ORDER BY created_at DESC, id DESC + WHERE 展開形）
# 専用の複合インデックス。MySQL のオプティマイザはタプル比較を range に展開
# しないため、WHERE 句を `created_at < :t OR (created_at = :t AND id < :i)` の
# 展開形で書いた上で、この (created_at, id) インデックスにより type: range に
# 解決させる。詳細と EXPLAIN は notes/4-pagination.md。
class AddIndexToPostsOnCreatedAtAndId < ActiveRecord::Migration[8.1]
  def change
    add_index :posts, [ :created_at, :id ]
  end
end

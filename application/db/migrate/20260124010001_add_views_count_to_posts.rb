class AddViewsCountToPosts < ActiveRecord::Migration[8.1]
  def change
    add_column :posts, :views_count, :integer, default: 0, null: false
    add_column :posts, :notifications_count, :integer, default: 0, null: false
    add_column :posts, :published, :boolean, default: false, null: false
  end
end

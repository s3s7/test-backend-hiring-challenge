# frozen_string_literal: true

class CreateTagsAndPostTags < ActiveRecord::Migration[8.1]
  def change
    create_table :tags do |t|
      t.string :name, null: false
      t.timestamps
      t.index :name, unique: true, name: "index_tags_on_name_unique"
    end

    create_table :post_tags do |t|
      t.references :post, null: false, foreign_key: true, type: :bigint
      t.references :tag, null: false, foreign_key: true, type: :bigint
      t.timestamps
      # 1 つの post に同じ tag が 2 回付かないようにする。
      t.index [ :post_id, :tag_id ], unique: true, name: "index_post_tags_on_post_id_and_tag_id_unique"
      # tag からの逆引き（tag 一覧で posts の件数集計など）。
      t.index [ :tag_id, :post_id ], name: "index_post_tags_on_tag_id_and_post_id"
    end
  end
end

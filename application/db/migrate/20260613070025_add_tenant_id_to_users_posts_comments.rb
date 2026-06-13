class AddTenantIdToUsersPostsComments < ActiveRecord::Migration[8.1]
  def change
    # 第8問: マルチテナント分離の expand 段階。
    # tenant_id は NULLABLE で追加。バックフィルと NOT NULL 化は別 migration（別 PR）。
    add_reference :users,    :tenant, foreign_key: true, null: true
    add_reference :posts,    :tenant, foreign_key: true, null: true
    add_reference :comments, :tenant, foreign_key: true, null: true

    # /api/v1/posts のキーセットページネーションをテナント単位で効かせるための複合 index。
    # 既存の (created_at, id) index は tenant 跨ぎの全件参照になり、テナント分離後はカバー率が落ちる。
    add_index :posts,
              [ :tenant_id, :created_at, :id ],
              name: "index_posts_on_tenant_id_and_created_at_and_id"
  end
end

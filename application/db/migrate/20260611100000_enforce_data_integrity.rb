# frozen_string_literal: true

# lib/ は autoload 対象外。db:migrate を素の環境（eager_load 抜き）で実行しても
# コケないよう、autoload に頼らず明示 require する。詳細は notes/3-validation.md。
require Rails.root.join("lib/data_fixer.rb").to_s

class EnforceDataIntegrity < ActiveRecord::Migration[8.1]
  def up
    # Step 1: 既存データを修復。DataFixer は rake task からも呼べる単一ソース。
    # ここで実行することで「rake を打ち忘れた deploy」でも制約付与が成功する。
    DataFixer.run!

    # Step 2: NOT NULL 化（修復後なので違反行は無い）。
    change_column_null :users, :name, false
    change_column_null :users, :email, false
    change_column_null :users, :password, false
    change_column_null :posts, :title, false
    change_column_null :posts, :content, false
    change_column_null :comments, :name, false
    change_column_null :comments, :content, false
    change_column_null :tenants, :subdomain, false

    # Step 3: 一意制約。column collation utf8mb4_0900_ai_ci により大小区別なく一意。
    add_index :users, :email, unique: true, name: "index_users_on_email_unique"
    add_index :tenants, :subdomain, unique: true, name: "index_tenants_on_subdomain_unique"
  end

  def down
    # データ修復は不可逆。down では制約のみ巻き戻し、データは復元しない。
    remove_index :tenants, name: "index_tenants_on_subdomain_unique"
    remove_index :users, name: "index_users_on_email_unique"

    change_column_null :tenants, :subdomain, true
    change_column_null :comments, :content, true
    change_column_null :comments, :name, true
    change_column_null :posts, :content, true
    change_column_null :posts, :title, true
    change_column_null :users, :password, true
    change_column_null :users, :email, true
    change_column_null :users, :name, true
  end
end

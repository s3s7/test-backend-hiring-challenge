require 'rails_helper'
require Rails.root.join('lib/data_fixer.rb').to_s

# DataFixer は migration 後の DB（NOT NULL + unique index 付き）で動かす。
# 重複 email を意図的に作るには users.email の unique index を一時的に外す必要がある。
#
# DDL を before(:each) や around(:each) で行うと、transactional fixtures が
# 開いている SAVEPOINT が MySQL の DDL auto-commit で破壊され、後続のクエリが
# "SAVEPOINT active_record_1 does not exist" でコケる。
# そのため DDL は before(:all)/after(:all) でこの describe 全体の "外側" に置く。
# 各 it ブロック内のデータ作成は通常通り transactional fixtures で rollback される。
RSpec.describe DataFixer do
  before(:all) do
    begin
      ActiveRecord::Base.connection.remove_index(:users, name: "index_users_on_email_unique")
    rescue ArgumentError
      # 既に index が無ければ何もしない
    end
  end

  after(:all) do
    has_index = ActiveRecord::Base.connection
      .indexes(:users).any? { |i| i.name == "index_users_on_email_unique" }
    unless has_index
      ActiveRecord::Base.connection.add_index(
        :users, :email, unique: true, name: "index_users_on_email_unique"
      )
    end
  end

  describe '.run!' do
    context '重複 email の統合' do
      it '残存 user は最古、posts/comments は付け替え、孤児ゼロ' do
        older = User.new(name: 'Older', email: 'admin@example.com', password: 'pw')
        older.save(validate: false)

        newer = User.new(name: 'Newer', password: 'pw')
        newer.email = 'Admin@example.com'
        newer.save(validate: false)

        User.where(id: older.id).update_all(created_at: 2.days.ago, updated_at: 2.days.ago)
        User.where(id: newer.id).update_all(created_at: 1.day.ago, updated_at: 1.day.ago)

        post = Post.create!(title: 't', content: 'c', user: newer)
        comment = Comment.create!(name: 'n', content: 'c', post: post, user: newer)

        described_class.run!

        survivors = User.where("LOWER(email) = ?", 'admin@example.com')
        expect(survivors.count).to eq(1)
        expect(survivors.first.id).to eq(older.id)
        expect(User.find_by(id: newer.id)).to be_nil

        expect(post.reload.user_id).to eq(older.id)
        expect(comment.reload.user_id).to eq(older.id)

        all_user_ids = User.pluck(:id)
        orphan_posts = Post.where.not(user_id: all_user_ids)
        orphan_comments = Comment.where.not(user_id: [ nil, *all_user_ids ])
        expect(orphan_posts.count).to eq(0)
        expect(orphan_comments.count).to eq(0)
      end

      it 'survivor 選定で valid (name/password が空でない) を最古より優先' do
        broken_older = User.new(email: 'pick@example.com', password: 'pw')
        broken_older.name = ''
        broken_older.save(validate: false)

        valid_newer = User.new(name: 'Keeper', email: 'PICK@example.com', password: 'pw')
        valid_newer.save(validate: false)

        User.where(id: broken_older.id).update_all(created_at: 2.days.ago, updated_at: 2.days.ago)
        User.where(id: valid_newer.id).update_all(created_at: 1.day.ago, updated_at: 1.day.ago)

        described_class.run!

        survivors = User.where("LOWER(email) = ?", 'pick@example.com')
        expect(survivors.count).to eq(1)
        expect(survivors.first.id).to eq(valid_newer.id)
      end
    end

    context '冪等性' do
      it '同じデータ状態で 2 回呼んでも結果が変わらない' do
        u1 = User.new(name: 'A', email: 'idem-a@example.com', password: 'pw')
        u1.save(validate: false)
        u2 = User.new(name: 'B', email: 'IDEM-A@example.com', password: 'pw')
        u2.save(validate: false)

        described_class.run!
        first_state = User.where("LOWER(email) = ?", 'idem-a@example.com').pluck(:id, :email).sort

        described_class.run!
        second_state = User.where("LOWER(email) = ?", 'idem-a@example.com').pluck(:id, :email).sort

        expect(second_state).to eq(first_state)
      end

      it 'クリーンな user に対する no-op（自分の作ったレコードは消えない）' do
        # 注: 他のテストで残った invalid 行を DataFixer が掃除することはあり得るので、
        # ここでは「自分の作ったクリーンな user が壊れない」だけを確認する。
        clean = User.create!(name: 'Clean', email: "clean-#{SecureRandom.hex(8)}@example.com", password: 'pw')
        before_attrs = clean.attributes.slice('id', 'name', 'email')

        described_class.run!

        reloaded = User.find_by(id: clean.id)
        expect(reloaded).not_to be_nil
        expect(reloaded.attributes.slice('id', 'name', 'email')).to eq(before_attrs)
      end
    end

    context 'email の小文字正規化' do
      it '大文字混じり email を LOWER に揃える（1 本 SQL）' do
        # 他テストの残骸と重複して consolidate で消されないよう、ランダム接頭辞を使う。
        prefix = "mixedcase-#{SecureRandom.hex(8)}"
        mixed = User.new(name: 'M', password: 'pw')
        mixed.email = "#{prefix}@Example.COM"
        mixed.save(validate: false)

        described_class.run!

        expect(mixed.reload.email).to eq("#{prefix}@example.com".downcase)
      end
    end
  end
end

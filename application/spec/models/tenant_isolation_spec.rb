require 'rails_helper'

# 第8問: 共有スキーマ + tenant_id 方式のクロステナント分離を検証する。
# for_current_tenant スコープが Current.tenant 配下の行のみを返すこと、
# 他テナント行を tenant_id で参照しようとすると validation で弾かれることを示す。
RSpec.describe 'マルチテナント分離', type: :model do
  let!(:tenant_a) { Tenant.create!(name: 'A', subdomain: "a-#{SecureRandom.hex(4)}") }
  let!(:tenant_b) { Tenant.create!(name: 'B', subdomain: "b-#{SecureRandom.hex(4)}") }

  let!(:user_a) do
    Current.tenant = tenant_a
    User.create!(name: 'ua', email: "ua-#{SecureRandom.hex(4)}@example.com", password: 'p')
  end

  let!(:user_b) do
    Current.tenant = tenant_b
    User.create!(name: 'ub', email: "ub-#{SecureRandom.hex(4)}@example.com", password: 'p')
  end

  let!(:post_a) do
    Current.tenant = tenant_a
    Post.create!(title: 't-a', content: 'c', user: user_a)
  end

  let!(:post_b) do
    Current.tenant = tenant_b
    Post.create!(title: 't-b', content: 'c', user: user_b)
  end

  describe 'for_current_tenant' do
    it 'Current.tenant = A のとき A の Post のみを返す' do
      Current.tenant = tenant_a
      expect(Post.for_current_tenant.pluck(:id)).to contain_exactly(post_a.id)
    end

    it 'Current.tenant = B のとき B の Post のみを返す' do
      Current.tenant = tenant_b
      expect(Post.for_current_tenant.pluck(:id)).to contain_exactly(post_b.id)
    end

    it 'User にも同様に tenant scoping が効く' do
      Current.tenant = tenant_a
      expect(User.for_current_tenant.pluck(:id)).to contain_exactly(user_a.id)
    end
  end

  describe '作成時の自動 tenant_id 付与' do
    it 'Current.tenant の id で tenant_id が埋まる' do
      Current.tenant = tenant_a
      post = Post.create!(title: 'auto', content: 'c', user: user_a)
      expect(post.tenant_id).to eq(tenant_a.id)
    end
  end

  describe 'クロステナントの参照禁止' do
    it '他テナントの tenant_id を明示しても validation で弾かれる' do
      Current.tenant = tenant_a
      post = Post.new(title: 'x', content: 'c', user: user_a, tenant_id: tenant_b.id)
      expect(post).to be_invalid
      expect(post.errors[:tenant_id]).to be_present
    end
  end
end

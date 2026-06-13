require 'rails_helper'

# 第9問: 低レイヤキャッシュの動作確認。
# test 環境は :null_store なので、この spec の間だけ MemoryStore に差し替えてキャッシュ挙動を検証する。
RSpec.describe Posts::FeedQuery, 'caching', type: :model do
  around do |example|
    original = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original
  end

  let(:tenant) { Tenant.find_by(subdomain: 'default') }
  let(:user) { User.create!(name: 'Alice', email: "cache-#{SecureRandom.hex(3)}@example.com", password: 'pw') }
  let!(:post_a) { Post.create!(title: 'a', content: 'a', user: user) }

  def call_feed
    described_class.new(scope: Post.for_current_tenant).cached_call
  end

  describe 'キャッシュヒット' do
    # cache_key_with_version を動かさずに DB を書き換え、2 回目の cached_call が
    # 古い結果を返すことで「2 回目はキャッシュから読まれた」ことを示す。
    # update_columns は updated_at を bump しないので、scope 集約値が変わらない。
    it '2 回目はキャッシュから返り、DB の最新値は反映されない' do
      first = call_feed
      expect(first.first[:title]).to eq('a')

      post_a.update_columns(title: 'a-bypassed-by-update_columns')

      second = call_feed
      expect(second).to eq(first)
      expect(second.first[:title]).to eq('a')
    end
  end

  describe 'Post の更新でキャッシュキーが変わる（自然失効）' do
    it 'Post#update で次回呼び出しはブロックが再実行される' do
      first = call_feed
      sleep 0.01
      post_a.update!(title: 'a2')

      result = call_feed
      expect(result.first[:title]).to eq('a2')
      expect(result).not_to eq(first)
    end
  end

  describe 'Comment 作成でキャッシュキーが変わる' do
    it 'belongs_to :post, touch: true で Post.updated_at が動き、comment_count 反映' do
      first = call_feed
      expect(first.first[:comment_count]).to eq(0)

      Comment.create!(name: 'c', content: 'c', post: post_a, user: user)

      result = call_feed
      expect(result.first[:comment_count]).to eq(1)
    end
  end

  describe 'テナント間のキャッシュ分離' do
    it 'tenant が違うとキャッシュバケットが分かれる' do
      Current.tenant = tenant
      a_result = call_feed
      expect(a_result.map { |h| h[:id] }).to include(post_a.id)

      other = Tenant.create!(name: 'Other', subdomain: "other-#{SecureRandom.hex(3)}")
      Current.tenant = other
      other_result = call_feed
      expect(other_result).to eq([])
    end
  end
end

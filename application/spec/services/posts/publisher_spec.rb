require 'rails_helper'

RSpec.describe Posts::Publisher do
  describe '#call' do
    let(:user) { User.create!(name: 'Alice', email: "pub-#{SecureRandom.hex(3)}@example.com", password: 'pw') }
    let(:post) { Post.create!(title: 't', content: 'c', user: user) }

    it 'published を true にして post を返す' do
      result = described_class.new(post).call

      expect(post.reload.published).to eq(true)
      expect(result).to eq(post)
    end

    it 'トランザクション内で post と関連 comments を id 昇順でロックする' do
      # 外部依存（DB ロック）をモックして呼び出し順序を検証する。
      c1 = Comment.create!(name: 'c1', content: 'a', post: post, user: user)
      c2 = Comment.create!(name: 'c2', content: 'b', post: post, user: user)

      call_order = []
      allow(post).to receive(:lock!) { call_order << :post_lock }
      [ c1, c2 ].each do |c|
        allow(c).to receive(:lock!) { call_order << :"comment_#{c.id}_lock" }
      end
      allow(post).to receive(:comments).and_return(double(order: [ c1, c2 ]))
      allow(post).to receive(:update!).with(published: true) { call_order << :update }

      described_class.new(post).call

      expect(call_order).to eq([
        :post_lock,
        :"comment_#{c1.id}_lock",
        :"comment_#{c2.id}_lock",
        :update
      ])
    end

    it '途中で例外が出れば変更はロールバックされる' do
      allow(post).to receive(:update!).and_raise(ActiveRecord::RecordInvalid.new(post))

      expect { described_class.new(post).call }.to raise_error(ActiveRecord::RecordInvalid)
      expect(post.reload.published).to eq(false)
    end
  end
end

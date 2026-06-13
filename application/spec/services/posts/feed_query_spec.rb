require 'rails_helper'

RSpec.describe Posts::FeedQuery do
  describe '#call' do
    let(:user) { User.create!(name: 'Alice', email: "feed-#{SecureRandom.hex(3)}@example.com", password: 'pw') }
    let!(:post) do
      Post.create!(
        title: "  Hello   World  ",
        content: "line1\nline2",
        user: user
      )
    end
    let!(:comment) { Comment.create!(name: 'c1', content: 'hi', post: post, user: user) }

    it 'スコープを eager load して整形済みハッシュを返す' do
      result = described_class.new.call

      expect(result.size).to eq(1)
      expect(result.first).to include(
        id: post.id,
        title: 'Hello World',
        author: 'Alice',
        body: 'line1 line2',
        comment_count: 1
      )
    end

    it 'limit を絞ると件数も制限される' do
      Post.create!(title: 't2', content: 'c2', user: user)
      Post.create!(title: 't3', content: 'c3', user: user)

      result = described_class.new(limit: 2).call

      expect(result.size).to eq(2)
    end

    it 'scope を差し替えて件数を 0 にできる（外部依存差し替えの確認）' do
      result = described_class.new(scope: Post.none).call

      expect(result).to eq([])
    end
  end
end

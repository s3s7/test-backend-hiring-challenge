require 'rails_helper'

RSpec.describe Posts::Exporter do
  describe '#call' do
    let(:user) { User.create!(name: 'Alice', email: "exp-#{SecureRandom.hex(3)}@example.com", password: 'pw') }
    let!(:post) { Post.create!(title: 'Hello', content: 'Body', user: user) }
    let!(:comment) { Comment.create!(name: 'c1', content: 'hi', post: post, user: user) }

    it '既存挙動と同じ "id,title,content,author,comment_count" を改行区切りで返す' do
      result = described_class.new.call

      expect(result).to eq("#{post.id},Hello,Body,Alice,1")
    end

    it 'scope を差し替えると対象が変わる（外部依存差し替えの確認）' do
      result = described_class.new(scope: Post.none).call

      expect(result).to eq('')
    end

    it '複数 post は改行で連結される' do
      post2 = Post.create!(title: 'World', content: 'Body2', user: user)

      result = described_class.new.call

      expect(result).to eq(
        "#{post.id},Hello,Body,Alice,1\n#{post2.id},World,Body2,Alice,0"
      )
    end
  end
end

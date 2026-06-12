require 'rails_helper'

RSpec.describe Comment, type: :model do
  let(:author) do
    User.create!(name: 'A', email: "a-#{SecureRandom.hex(8)}@example.com", password: 'password')
  end
  let(:post) do
    Post.create!(title: 't', content: 'c', user: author)
  end

  it 'belongs to a user' do
    association = Comment.reflect_on_association(:user)
    expect(association.macro).to eq(:belongs_to)
  end

  it 'belongs to a post' do
    association = Comment.reflect_on_association(:post)
    expect(association.macro).to eq(:belongs_to)
  end

  describe 'バリデーション' do
    it 'name と content があれば valid' do
      expect(Comment.new(name: 'n', content: 'c', post: post)).to be_valid
    end

    it 'name が空なら invalid' do
      comment = Comment.new(name: '', content: 'c', post: post)
      expect(comment).to be_invalid
      expect(comment.errors[:name]).to be_present
    end

    it 'content が空なら invalid' do
      comment = Comment.new(name: 'n', content: '', post: post)
      expect(comment).to be_invalid
      expect(comment.errors[:content]).to be_present
    end

    it 'user は optional（user なしで valid）' do
      expect(Comment.new(name: 'n', content: 'c', post: post)).to be_valid
    end
  end
end

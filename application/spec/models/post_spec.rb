require 'rails_helper'

RSpec.describe Post, type: :model do
  it 'ユーザーに属する' do
    association = Post.reflect_on_association(:user)
    expect(association.macro).to eq(:belongs_to)
  end

  it 'タイトルなしでは無効' do
    post = Post.new(content: 'Test content', user: User.new)
    expect(post).to be_invalid
  end

  it 'コンテンツなしでは無効' do
    post = Post.new(title: 'Test title', user: User.new)
    expect(post).to be_invalid
  end
end
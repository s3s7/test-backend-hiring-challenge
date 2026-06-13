require 'rails_helper'

RSpec.describe Post, type: :model do
  it 'ユーザーに属する' do
    association = described_class.reflect_on_association(:user)
    expect(association.macro).to eq(:belongs_to)
  end

  it 'タイトルなしでは無効' do
    post = described_class.new(content: 'Test content', user: User.new)
    expect(post).to be_invalid
  end

  it 'コンテンツなしでは無効' do
    post = described_class.new(title: 'Test title', user: User.new)
    expect(post).to be_invalid
  end
end

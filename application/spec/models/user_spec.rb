require 'rails_helper'

RSpec.describe User, type: :model do
  it '名前なしでは無効' do
    user = User.new(email: 'test@example.com')
    expect(user).to be_invalid
  end

  it 'メールなしでは無効' do
    user = User.new(name: 'Test')
    expect(user).to be_invalid
  end

  it '多くの投稿を持つ' do
    association = User.reflect_on_association(:posts)
    expect(association.macro).to eq(:has_many)
  end
end
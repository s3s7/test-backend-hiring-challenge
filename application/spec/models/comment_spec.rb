require 'rails_helper'

RSpec.describe Comment, type: :model do
  it 'belongs to a user' do
    association = Comment.reflect_on_association(:user)
    expect(association.macro).to eq(:belongs_to)
  end

  it 'belongs to a post' do
    association = Comment.reflect_on_association(:post)
    expect(association.macro).to eq(:belongs_to)
  end
end
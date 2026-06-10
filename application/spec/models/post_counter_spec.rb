require 'rails_helper'

RSpec.describe Post, type: :model do
  before(:all) do
    @author = User.create!(name: 'Counter Author', email: "author-#{rand(100)}@example.com", password: 'password')
  end

  it 'starts with zero views' do
    post = Post.create!(title: 'Counter', content: 'body', user: @author)
    expect(post.views_count).to eq(0)
  end

  it 'keeps a single account per author email' do
    expect(User.where(email: @author.email).count).to eq(1)
  end

  it 'counts only the posts created in this example' do
    Post.create!(title: 'A', content: 'body', user: @author)
    Post.create!(title: 'B', content: 'body', user: @author)
    expect(@author.posts.count).to eq(2)
  end
end

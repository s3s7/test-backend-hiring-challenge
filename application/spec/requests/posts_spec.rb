require 'rails_helper'

# 受け入れ基準: サービス層へ切り出しても API の挙動が変わらないことの検証。
# 既存実装と同じ status / Content-Type / ボディ形式が返ることだけを見る。
RSpec.describe 'Posts (refactored to service layer)', type: :request do
  let(:user) { User.create!(name: 'Alice', email: "req-#{SecureRandom.hex(3)}@example.com", password: 'pw') }
  let!(:post_record) { Post.create!(title: '  Hi  ', content: 'body', user: user) }

  describe 'GET /posts/feed' do
    it '200 と { data: [...] } を返す' do
      get '/posts/feed'

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.fetch('data')).to be_an(Array)
      first = body['data'].first
      expect(first.keys).to contain_exactly('id', 'title', 'author', 'body', 'comment_count')
      expect(first['title']).to eq('Hi') # normalize で詰めた
      expect(first['author']).to eq('Alice')
    end
  end

  describe 'GET /posts/export' do
    it '200 と CSV テキストを返す（id,title,content,author,comment_count）' do
      get '/posts/export'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("#{post_record.id},  Hi  ,body,Alice,0")
    end
  end

  describe 'PATCH /posts/:id/publish' do
    it '対象 post を redirect_to し、published を true にする' do
      patch "/posts/#{post_record.id}/publish"

      expect(response).to redirect_to(post_record)
      expect(post_record.reload.published).to eq(true)
    end
  end
end

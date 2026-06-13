#!/usr/bin/env ruby
# frozen_string_literal: true

# /posts/feed の CPU プロファイル取得用スクリプト。
#
# StackProf は wrap した Ruby プロセスのみを観測する。
# Net::HTTP 越しに Puma サーバを叩くと、プロファイルされるのは HTTP クライアント側
# (Net::HTTP/TCPSocket) であり、PostsController#feed の Ruby コードは観測できない。
# そこで Rack::MockRequest で env を作り、Rails.application.call を直接呼び出すことで、
# 同一プロセス内で feed アクションを実行 → StackProf がコントローラ内部の CPU 使用を捉える。
#
# 使い方:
#   docker compose exec app bin/rails runner script/profile_feed.rb tmp/feed.dump 20
#   docker compose exec app stackprof tmp/feed.dump --text | head -40

require "stackprof"
require "rack/mock"

out_path = ARGV[0] || "tmp/feed.dump"
iterations = (ARGV[1] || "20").to_i

# データ投入: 100 posts × 数 comments
ActiveRecord::Base.transaction do
  PostTag.delete_all
  Tag.delete_all
  Comment.delete_all
  Post.delete_all
  User.delete_all
  user = User.create!(name: "Profile Author", email: "profile-#{SecureRandom.hex(4)}@example.com", password: "pw")
  100.times do |i|
    p = Post.create!(title: "Title #{i}   with   irregular   whitespace   here", content: "Body #{i}   spaces", user: user)
    3.times { |j| Comment.create!(name: "n#{j}", content: "c#{j}", post: p, user: user) }
  end
end

env = Rack::MockRequest.env_for("http://localhost:3000/posts/feed", method: "GET")
env["HTTP_HOST"] = "localhost"
env["SERVER_NAME"] = "localhost"

# ウォームアップ: autoload / クエリプラン / コネクション確立を除外
3.times { Rails.application.call(env.dup) }

puts "Seeded. Starting profile (#{iterations} iterations) inside the runner process..."

StackProf.run(mode: :cpu, out: out_path, raw: false) do
  iterations.times { Rails.application.call(env.dup) }
end

puts "Done. Output: #{out_path}"

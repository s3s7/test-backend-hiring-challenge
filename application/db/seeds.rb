# このファイルは、すべての環境（本番、開発、テスト）でアプリケーションを実行するために必要なレコードの存在を保証します。
# このコードはべき等であるべきで、どの環境でもいつでも実行可能です。
# データは bin/rails db:seed コマンドでロードできます（または db:setup でデータベースと共に作成）。
#
# 例:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

[
  { name: 'Acme', subdomain: 'acme' },
  { name: 'Globex', subdomain: 'globex' }
].each { |attrs| Tenant.create!(attrs) }

admin = User.create(name: 'Admin', email: 'admin@example.com', password: 'password')

100.times { |i| Post.create(user: admin, title: "Post #{i}", content: 'lorem') }

Post.all.each do |post|
  3.times { |i| Comment.create(name: "#{i}_anonymous", post: post, content: "Comment #{i} on #{post.title}") }
end

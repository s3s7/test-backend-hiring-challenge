class PostsController < ApplicationController
  def index
    @posts = Post.for_current_tenant.includes(:user).limit(50)
  end

  def show
    @post = Post.for_current_tenant.includes(comments: :user).find(params[:id])
    @post.update(views_count: @post.views_count + 1)
  end

  def feed
    render json: { data: Posts::FeedQuery.new(scope: Post.for_current_tenant).call }
  end

  def export
    send_data(Posts::Exporter.new(scope: Post.for_current_tenant).call, filename: "posts.csv")
  end

  def new
    @post = Post.new
  end

  def create
    user = User.create(params[:user])
    post = Post.create(title: params[:title], user: user)
    redirect_to post
  end

  def edit
    @post = Post.for_current_tenant.find(params[:id])
  end

  def update
    @post = Post.for_current_tenant.find(params[:id])
    @post.update(params[:post])
    redirect_to @post
  end

  def publish
    post = Post.for_current_tenant.find(params[:id])
    Posts::Publisher.new(post).call
    redirect_to post
  end

  def destroy
    @post = Post.for_current_tenant.find(params[:id])
    @post.destroy
    redirect_to posts_path
  end
end

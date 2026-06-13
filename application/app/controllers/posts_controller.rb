class PostsController < ApplicationController
  def index
    @posts = Post.includes(:user).limit(50)
  end

  def show
    @post = Post.includes(comments: :user).find(params[:id])
    @post.update(views_count: @post.views_count + 1)
  end

  def feed
    render json: { data: Posts::FeedQuery.new.call }
  end

  def export
    send_data(Posts::Exporter.new.call, filename: "posts.csv")
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
    @post = Post.find(params[:id])
  end

  def update
    @post = Post.find(params[:id])
    @post.update(params[:post])
    redirect_to @post
  end

  def publish
    post = Post.find(params[:id])
    Posts::Publisher.new(post).call
    redirect_to post
  end

  def destroy
    @post = Post.find(params[:id])
    @post.destroy
    redirect_to posts_path
  end
end

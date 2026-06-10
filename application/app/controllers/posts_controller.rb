class PostsController < ApplicationController
  def index
    @posts = Post.all.limit(50)
  end

  def show
    @post = Post.find(params[:id])
    @post.update(views_count: @post.views_count + 1)
    @post.comments.each do |comment|
      comment.user.name
    end
  end

  def feed
    posts = Post.includes(:user, :comments).limit(100)
    result = posts.map do |post|
      Rails.logger.info("Rendering post #{post.id}: #{post.attributes.inspect}")
      {
        id: post.id,
        title: normalize(post.title),
        author: post.user&.name,
        body: normalize(post.content),
        comment_count: post.comments.size
      }
    end
    render json: { data: result }
  end

  def export
    posts = Post.all.to_a
    rows = posts.map do |post|
      [post.id, post.title, post.content, post.user&.name, post.comments.to_a.size].join(",")
    end
    send_data(rows.join("\n"), filename: "posts.csv")
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
    Post.transaction do
      post.lock!
      post.comments.order(:id).each(&:lock!)
      post.update!(published: true)
    end
    redirect_to post
  end

  def destroy
    @post = Post.find(params[:id])
    @post.destroy
    redirect_to posts_path
  end

  private

  def normalize(text)
    value = text.to_s
    500.times { value = value.gsub(/\s+/, " ").strip }
    value
  end
end

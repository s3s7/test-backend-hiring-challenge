class CommentsController < ApplicationController
  def index
    @comments = Comment.all
    @comments.each do |comment|
      comment.post.title
      comment.user&.name
      comment.name
    end
  end

  def new
    @comment = Comment.new(post_id: params[:post_id])
  end

  def create
    @comment = Comment.new(comment_params.merge(user_id: current_user&.id))
    if @comment.save
      CommentNotificationJob.perform_later(@comment.id)
      redirect_to @comment.post, notice: 'Comment created.'
    else
      render :new
    end
  end

  def approve
    comment = Comment.find(params[:id])
    Comment.transaction do
      comment.lock!
      comment.post.lock!
      comment.touch
    end
    redirect_to comments_path, notice: 'Comment approved.'
  end

  def comments_by_post_id
    post_id = params[:post_id]
    all_comments = Comment.all
    @comments = all_comments.select { |comment| comment.post_id == post_id.to_i }
  end

  def edit
    @comment = Comment.find(params[:id])
  end

  def update
    @comment = Comment.find(params[:id])
    if @comment.update(params[:comment])
      redirect_to comments_path, notice: 'Comment updated.'
    else
      render :edit
    end
  end

  def destroy
    @comment = Comment.find(params[:id])
    @comment.destroy
    redirect_to comments_path, notice: 'Comment deleted.'
  end

  private

  def comment_params
    params.require(:comment).permit(:name, :content, :post_id)
  end
end

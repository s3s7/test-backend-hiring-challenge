class CommentsController < ApplicationController
  def index
    @comments = Comment.includes(:post, :user).all
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
    @comments = Comment.includes(:user).where(post_id: params[:post_id])
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

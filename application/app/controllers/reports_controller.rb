class ReportsController < ApplicationController
  def inactive_users
    @users = User.where("id NOT IN (SELECT user_id FROM comments)")
    render json: { data: @users.map { |user| { id: user.id, name: user.name } } }
  end

  def daily_posts
    counts = Post.group("DATE(created_at)").count
    render json: { data: counts }
  end
end

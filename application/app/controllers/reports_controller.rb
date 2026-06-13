class ReportsController < ApplicationController
  # 第8問: NOT IN サブクエリは comments.user_id に NULL があると外側全体が空になる
  # （SQL の 3 値論理）。NOT EXISTS / LEFT JOIN に書き換えることで NULL 安全 + index 活用を両立する。
  # 加えて current tenant にスコープする。
  def inactive_users
    @users = User.for_current_tenant
                 .left_joins(:comments)
                 .where(comments: { id: nil })
                 .distinct
    render json: { data: @users.map { |user| { id: user.id, name: user.name } } }
  end

  def daily_posts
    counts = Post.for_current_tenant.group("DATE(created_at)").count
    render json: { data: counts }
  end
end

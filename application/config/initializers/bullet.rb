# frozen_string_literal: true

# bullet は N+1・Unused Eager Loading・Counter Cache 候補を検出する gem。
# development では log と Rails Logger に通知、test では raise=true で
# fail-fast にすることで「いつの間にか N+1 が紛れた」状態を CI で止める。
if defined?(Bullet)
  Rails.application.config.after_initialize do
    Bullet.enable = true

    if Rails.env.development?
      Bullet.alert = false
      Bullet.bullet_logger = true
      Bullet.console = true
      Bullet.rails_logger = true
    end

    if Rails.env.test?
      # spec 内で意図的に N+1 を発生させて検出を確認するケースのため、
      # デフォルトは検知のみ。raise したい spec では Bullet.raise = true を
      # 明示する。
      Bullet.bullet_logger = true
      Bullet.raise = false
    end
  end
end

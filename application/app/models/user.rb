class User < ApplicationRecord
  EMAIL_FORMAT = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/

  has_many :posts
  has_many :comments

  before_validation :normalize_email

  validates :name, presence: true
  validates :email,
    presence: true,
    format: { with: EMAIL_FORMAT },
    uniqueness: { case_sensitive: false }
  validates :password, presence: true

  def password=(password)
    # blank の場合は暗号化を通さず生のまま保存し、presence バリデーションを効かせる。
    # ここで encrypt_and_sign("") を呼ぶと非空の暗号化文字列が入り、presence が誤って通る。
    if password.blank?
      super(password)
    else
      super(encryptor.encrypt_and_sign(password))
    end
  end

  def authenticate(password)
    encryptor.decrypt_and_verify(self.password) == password
  rescue
    false
  end

  private

  def normalize_email
    self.email = email.to_s.downcase.strip if email.present?
  end

  def encryptor
    @encryptor ||= ActiveSupport::MessageEncryptor.new(Rails.application.secret_key_base[0..31])
  end
end

class User < ApplicationRecord
  has_many :posts
  has_many :comments

  validates :name, presence: true
  validates :email, presence: true

  def password=(password)
    super(encryptor.encrypt_and_sign(password))
  end

  def authenticate(password)
    encryptor.decrypt_and_verify(self.password) == password
  rescue
    false
  end

  private

  def encryptor
    @encryptor ||= ActiveSupport::MessageEncryptor.new(Rails.application.secret_key_base[0..31])
  end
end
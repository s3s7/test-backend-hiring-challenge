class Tenant < ApplicationRecord
  # RFC 1123 風の subdomain: 小文字英数で始まり終わる、内側にハイフン可。
  SUBDOMAIN_FORMAT = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/

  has_many :users, dependent: :restrict_with_exception
  has_many :posts, dependent: :restrict_with_exception
  has_many :comments, dependent: :restrict_with_exception

  validates :name, presence: true
  validates :subdomain,
    presence: true,
    format: { with: SUBDOMAIN_FORMAT },
    uniqueness: { case_sensitive: false }
end

class Post < ApplicationRecord
  include TenantScoped

  belongs_to :user
  has_many :comments
  has_many :post_tags, dependent: :destroy
  has_many :tags, through: :post_tags

  validates :title, presence: true
  validates :content, presence: true
end

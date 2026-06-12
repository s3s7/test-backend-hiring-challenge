class Comment < ApplicationRecord
  belongs_to :post
  belongs_to :user, optional: true

  validates :name, presence: true
  validates :content, presence: true
end

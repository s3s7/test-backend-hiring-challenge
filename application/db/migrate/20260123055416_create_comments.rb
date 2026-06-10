class CreateComments < ActiveRecord::Migration[8.1]
  def change
    create_table :comments do |t|
      t.text :name
      t.text :content
      t.references :post, null: false
      t.references :user, null: true

      t.timestamps
    end
  end
end

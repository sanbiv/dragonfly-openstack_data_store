class CreateThumbs < ActiveRecord::Migration
  def change
    create_table :thumbs do |t|
      t.string :signature, null: false
      t.string :uid, null: false

      t.timestamps null: false
    end

    add_index :thumbs, :signature, :unique => true
    add_index :thumbs, :uid, :unique => true
  end
end

class Thumb < ActiveRecord::Base
  alias_attribute :file_uid, :uid

  dragonfly_accessor :file, app: :thumbnails


  def self.empty!
    find_each do |item|
      item.destroy
    end
  end
end

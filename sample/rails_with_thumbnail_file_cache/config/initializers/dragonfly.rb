require 'dragonfly'

# Configure

def subdir_thumb
  ['thumbnails', Rails.env]
end

def get_asset_path(path)
  case path
    when String
      path = "/#{path}" unless path.start_with?('/')
      return path
    when Array
      return "/#{path.join('/')}"
    else
      raise ArgumentError, "invalid argument in get_asset_path"
  end
end

def get_thumbnail_dir_and_file(job)
  path_or_uid = job.uid
  unless path_or_uid
    path_or_uid = job.steps.first.path rescue nil
    path_or_uid = path_or_uid.from Rails.root.to_s.length + 1 if path_or_uid
  end
  return nil unless path_or_uid
  basename = "#{job.signature}_#{::File.basename(path_or_uid)}"

  subdir_thumb_file = subdir_thumb.dup
  subdir_thumb_file.push *::File.dirname(path_or_uid).split(::File::SEPARATOR)

  full_path = ::Rails.root.join 'public', subdir_thumb_file.join(::File::SEPARATOR)

  return [basename, subdir_thumb_file, full_path]
end

Dragonfly.app.configure do
  plugin :imagemagick

  verify_urls true
  secret Rails.application.secrets.dragonfly || Rails.application.secrets.secret_key_base

  url_format "/media/:job/:basename-:style.:ext"
  ######################################################################################################################
  ######################################################################################################################

  credentials = Rails.application.secrets['open_stack']
  datastore :openstack_swift,
            container: "myrepository-#{ENV['RACK_ENV'] || ENV['RAILS_ENV'] || 'development'}",
            access_control_allow_origin: '*',
            openstack: {
                auth_url:     "#{credentials['auth_url']}/v3/auth/tokens", #https://identity.open.softlayer.com/v3/auth/tokens
                api_key:      credentials['password'],
                username:     credentials['username'],
                project_id:   credentials['projectId'],
                region:       credentials['region'],
                #set domain_name
                domain_name:  credentials['domainName'],
                #or...user_id (this will make a different auth request and domain_name will ignored)
                #user_id: credentials['userId']
                temp_url_key:         ENV['OPENSTACK_TEMP_URL_KEY'] || credentials['temp_url_key'] || Rails.application.secrets['secret_key_base'],
                temp_url_expires_in:  3600
            },
            set_meta_temp_url_key_on_startup: true,
            url_scheme: 'https'

  # Override the .url method...
  define_url do |app, job, opts|
    #thumb = Thumb.find_by(signature: job.signature)
    # If (fetch 'some_uid' then resize to '40x40') has been stored already, give the datastore's remote url ...
    #if thumb
      #app.datastore.url_for(thumb.uid)
      # ...otherwise give the local Dragonfly server url
    #else
    #  app.server.url_for(job)
    #end

    filename, subdir_thumb_file_array, full_path_dir = get_thumbnail_dir_and_file(job) rescue nil
    unless filename
      app.server.url_for job
    else
      file_path = ::File.join(full_path_dir, filename)
      if File.exist?(file_path)
        get_asset_path(subdir_thumb_file_array.push filename)
      else
        ext = ::File.extname(job.uid||(job.steps.first.path rescue '')).strip.gsub('.', '')
        ext = 'file' if ext.blank?

        job.url_attributes.ext = ext
        #job.url_attributes.file_name = ::File.basename(job.uid) #Che contiene anche estensione, oltre al nome del file.
        app.server.url_for(job)
      end
    end
  end

  # Before serving from the local Dragonfly server...
  before_serve do |job, env|
    # ...store the thumbnail in the datastore...
    #uid = job.store

    # ...keep track of its uid so next time we can serve directly from the datastore
    #Thumb.create!(uid: uid, signature: job.signature)

    filename, subdir_thumb_file_array, full_path_dir = get_thumbnail_dir_and_file(job) rescue nil
    if filename
      file_path = ::File.join(full_path_dir, filename)
      unless ::File.exist?(file_path)
        require 'fileutils'
        ::FileUtils.mkdir_p(full_path_dir, mode: 0775) unless ::Dir.exist?(full_path_dir)
        job.to_file file_path
      end
    end
  end

  fetch_file_whitelist [
                            %r(#{Rails.root.join('public')}.)
                       ]
end

# Logger
Dragonfly.logger = Rails.logger

# Mount as middleware
Rails.application.middleware.use Dragonfly::Middleware

# Add model functionality
if defined?(ActiveRecord::Base)
  ActiveRecord::Base.extend Dragonfly::Model
  ActiveRecord::Base.extend Dragonfly::Model::Validations
end

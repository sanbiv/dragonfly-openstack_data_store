require 'dragonfly'

credentials = Rails.application.secrets.open_stack

openstack_settings = {
    auth_url:         "#{credentials['auth_url']}/v3/auth/tokens", #https://identity.open.softlayer.com/v3/auth/tokens
    api_key:          credentials['password'],
    username:         credentials['username'],
    project_id:       credentials['projectId'],
    region:           credentials['region'],
    #set domain_name
    domain_name:      credentials['domainName'],
    #or...user_id (this will make a different auth request and domain_name will ignored)
    #user_id: credentials['userId']
    temp_url_key:         ENV['OPENSTACK_TEMP_URL_KEY'] || credentials['temp_url_key'] || Rails.application.secrets['secret_key_base'],
    temp_url_expires_in:  3600
}

container_name = "ibm-filerepository-#{ENV['RACK_ENV'] || ENV['RAILS_ENV'] || 'development'}"

dragonfly_secret = Rails.application.secrets.dragonfly || Rails.application.secrets.secret_key_base


Dragonfly.app(:thumbnails).configure do
  plugin :imagemagick

  verify_urls true
  secret dragonfly_secret

  url_format "/media/:job/:basename-:style.:ext"
  ######################################################################################################################
  ######################################################################################################################


  datastore :openstack_swift,
            container: "#{container_name}-thumbnails",
            access_control_allow_origin: '*',
            openstack: openstack_settings,
            url_scheme: 'https'
end

Dragonfly.app.configure do
  plugin :imagemagick

  verify_urls true
  secret dragonfly_secret

  url_format "/media/:job/:basename-:style.:ext"
  ######################################################################################################################
  ######################################################################################################################


  datastore :openstack_swift,
            container: container_name,
            access_control_allow_origin: '*',
            openstack: openstack_settings,
            url_scheme: 'https'

  # Override the .url method...
  define_url do |app, job, opts|
    thumb = ::Thumb.find_by(signature: job.signature)
    # If (fetch 'some_uid' then resize to '40x40') has been stored already, give the datastore's remote url ...
    if thumb
      Dragonfly.app(:thumbnails).datastore.url_for(thumb.uid)
      # ...otherwise give the local Dragonfly server url
    else
      #ext = ::File.extname(job.uid || (job.steps.first.path rescue '')).strip.gsub('.', '')
      #ext = 'thumb' if ext.blank?

      job.url_attributes.ext = 'thumb'
      #job.url_attributes.file_name = ::File.basename(job.uid) #Che contiene anche estensione, oltre al nome del file.
      app.server.url_for(job)
    end
  end

  # Before serving from the local Dragonfly server...
  before_serve do |job, env|
    # ...store the thumbnail in the datastore...
    #uid = job.store

    # ...keep track of its uid so next time we can serve directly from the datastore
    # Thread.new do
    #   Thumb.create!(file: job, signature: job.signature)
    # end
    Thread.new do
      Thumb.create!(file: job, signature: job.signature)
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

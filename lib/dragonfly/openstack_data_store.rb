#require 'fog/openstack' #see https://github.com/fog/fog/blob/master/lib/fog/openstack/docs/storage.md
require 'swift_client'
require 'dragonfly'
require 'cgi'
require 'uri'
require 'securerandom'

Dragonfly::App.register_datastore(:openstack_swift){ Dragonfly::OpenStackDataStore }
Thread.report_on_exception = true

module Dragonfly
  class OpenStackDataStore
    MAX_RETRY = 10

    # Exceptions
    #class NotConfigured < RuntimeError; end

    attr_accessor :container_name,
                  :fog_storage_options, :openstack_options, :storage_headers,
                  :access_control_allow_origin, :default_expires_in,
                  :url_scheme, :url_host, :url_port, :root_path

    attr_writer   :set_meta_temp_url_key_on_startup

    def initialize(opts={})
      # case opts
      #   when Hash then opts
      #   when String
      #     file = File.expand_path(opts, __FILE__)
      #     fail "#{opts} is not a file" unless File.exists?(file) && !File.directory?(file)
      #     require 'yaml'
      #     opts = YAML.load(opts)
      # end
      fail "opts must be an Hash" unless opts.is_a?(Hash)
      ### Symbolizing keys
      opts = opts.inject({}) do |hash, (key, value)|
        hash[(key.to_sym rescue key)] = value
        hash
      end
      fail "opts must contain :openstack & must be an Hash" unless opts.key?(:openstack) && opts[:openstack].is_a?(Hash)

      @environment         = opts.delete(:environment) || 'development'
      @container_name      = if opts[:container]
                               opts[:container]
                             elsif defined?(::Rails)
                               "#{Rails.application.class.name.split('::').first.underscore}-#{@environment}"
                             else
                               "dragonfly-system-#{@environment}"
                             end

      # @fog_storage_options = opts[:fog_storage_options] || {}
      @openstack_options   = opts[:openstack].inject({}) do |memo, item|
        key, value = item
        memo[key.to_sym] = value
        memo
      end
      @default_expires_in = @openstack_options.delete(:temp_url_expires_in).to_i.nonzero? || 3600

      @access_control_allow_origin = opts[:access_control_allow_origin] || '*'

      @storage_headers  = opts[:storage_headers] || {}
      @url_scheme       = opts[:url_scheme] || 'http'
      @url_host         = opts[:url_host]
      @url_port         = opts[:url_port]
      @root_path        = opts[:root_path]
      @set_meta_temp_url_key_on_startup = opts.fetch(:set_meta_temp_url_key_on_startup, false)
    end

    def set_meta_temp_url_key_on_startup?
      @set_meta_temp_url_key_on_startup
    end

    def environment
      @environment ||= ENV['RACK_ENV'] || ENV['RAILS_ENV'] || 'development'
    end

    def environment=(environment)
      @environment = environment ? environment.to_s.downcase : nil
    end


    def write(content, opts={})
      #TODO: Upload large files. See https://github.com/fog/fog/blob/master/lib/fog/openstack/docs/storage.md#upload_large_files
      uid = opts[:path] || generate_uid(content.name || 'file')

      headers = {'x-original-name' => content.name}
      headers.merge!(opts[:headers]) if opts[:headers]
      # thread = Thread.new do
      #   sleep 30
      Dragonfly.info "Uploading #{content.name} (#{content.mime_type}) file on openstack swift"

      rescuing_socket_errors do
        #content.data....
        content.file do |file_io|
          # container.files.create({
          #                            :key           => full_path(uid),
          #                            :body          => f,
          #                            :content_type  => content.mime_type,
          #                            :metadata      => full_storage_headers(headers, content.meta),
          #                            :access_control_allow_origin => access_control_allow_origin
          #                        })
          swift_client.put_object(full_path(uid),
                                  file_io,
                                  container_name,
                                  full_storage_headers(headers, content.meta),
                                  {
                                    :access_control_allow_origin => access_control_allow_origin
                                  })
        end
      end
      # end

      uid
    end

    def read(uid)
      rescuing_socket_errors do
        object = swift_client.get_object(full_path(uid), container_name)
        # Dragonfly.debug "reading #{uid}: #{object.headers} #{object.parsed_response} -- #{object.body}"
        [
            object.body,                      # can be a String, File, Pathname, Tempfile
            headers_to_meta(object.headers)   # the same meta Hash that was stored with write
        ]
      end
    rescue => e
      Dragonfly.warn("#{self.class.name} read error: #{e}")
      nil # return nil if not found
    end

    def destroy(uid)
      Thread.new do
        rescuing_socket_errors do
          begin
            swift_client.delete_object(full_path(uid), container_name)
          rescue => e
            Dragonfly.warn("#{self.class.name} destroy error: #{e}")
          end
        end
      end
    end

    def url_for(uid, opts={})
      #ensure_meta_temp_url_key! if set_meta_temp_url_key_on_startup
      file_key = full_path(uid)
      expires_in = (opts[:expires_in].to_i.nonzero?) || @default_expires_in
      expires_at = Time.now.to_i + expires_in

      #file = container.files.get(file_key)
      #return nil unless file
      #file.url(expires_at)

      opts = {
          scheme: @url_scheme,
          host:   @url_host,
          port:   @url_port,
      }.merge(opts)
      method = opts[:scheme] == 'https' ? :get_object_https_url : :get_object_http_url

      # Dragonfly.debug "file temp url #{uid} in #{container_name}"
      url = temp_url(file_key, container_name, expires_in: opts.fetch(:expires_in) { openstack_options[:temp_url_expires_in] })

      if opts[:query]
        opts[:query] = case opts[:query]
                         when Hash, Array then URI.encode_www_form(opts[:query])
                         else opts[:query].to_s
                       end
        url = "#{url}&#{opts[:query]}"
      end
      if opts[:inline]
        url = "#{url}&inline"
      end
      url
    end


    def temp_url(object_name, container_name, opts = {})
      raise(SwiftClient::EmptyNameError) if object_name.empty? || container_name.empty?
      raise(SwiftClient::TempUrlKeyMissing) unless openstack_options[:temp_url_key]
      object_name == URI.escape(object_name)

      expires = (Time.now + (opts[:expires_in] || 3600).to_i).to_i
      uri = "#{swift_client.storage_url}/#{container_name}/#{object_name}"
      # Dragonfly.debug "temp_url #{uri}"
      path = URI.parse(uri).path

      signature = OpenSSL::HMAC.hexdigest("sha1", openstack_options[:temp_url_key], "GET\n#{expires}\n#{path}")

      "#{uri}?temp_url_sig=#{signature}&temp_url_expires=#{expires}"
    end

    def storage
      retry_times = 0
      @storage ||= begin
        begin
          # fog_storage = ::Fog::Storage.new(full_storage_options)
          swift_client = SwiftClient.new(swift_client_options)
          ensure_container_initialized(swift_client: swift_client)
        rescue => e
          should_retry = retry_times < MAX_RETRY
          Dragonfly.warn("#{e.class}: #{e.message} (#{should_retry ? " RETRYING #{retry_times}" : ''})")
          retry_times += 1
          # puts "retrying #{retry_times}"
          retry if should_retry
        end
        if openstack_options[:temp_url_key] && set_meta_temp_url_key_on_startup?
          set_meta_temp_url_key!(swift_client: swift_client)
        end
        swift_client
      end

      @storage
    end
    alias :swift_client :storage

    def set_meta_temp_url_key!(key = nil, force = false, swift_client: nil)
      return true if @_meta_temp_url_key_sent && !force
      key ||= openstack_options[:temp_url_key]
      if key
        begin
          swift_client ||= self.swift_client
          # storage_instance.post_set_meta_temp_url_key(openstack_options[:temp_url_key])

          Thread.new do
            headers_account = {
                #'X-Account-Meta-Access-Control-Allow-Origin' => "*",
                'X-Account-Meta-Temp-Url-Key' => key
            }.compact
            swift_client.post_account(headers_account)

            if container_name
              headers_container = {
                  'X-Container-Meta-Access-Control-Allow-Origin' => "*",
                  #'X-Container-Meta-Temp-Url-Key' => Rails.application.secrets.open_stack['temp_url_key'].presence
              }.compact
              swift_client.post_container(container_name, headers_container)
            end
          end

          @_meta_temp_url_key_sent = true
        rescue => e
          Dragonfly.warn("#{e.class}: #{e.message}")
          @_meta_temp_url_key_sent = false
        end
      end
      @_meta_temp_url_key_sent
    end
    alias ensure_meta_temp_url_key! set_meta_temp_url_key!

    def meta_temp_url_key_sent?
      @_meta_temp_url_key_sent
    end

    # def container
    #   ensure_container_initialized
    #   @container ||= begin
    #     rescuing_socket_errors{
    #       storage.directories.get(container_name)
    #     }
    #   end
    # end

    def container_exists?(swift_client: nil)
      _response = (swift_client || self.swift_client).head_container(container_name)
      true
    rescue SwiftClient::ResponseError => e
      if e.code == 404
        false
      else
        raise e
      end
    end

    private

    def ensure_container_initialized(swift_client: nil)
      unless @container_initialized
        rescuing_socket_errors {
          # storage.directories.create(:key => container_name)
          # Dragonfly.debug "Creo il container"
          (swift_client || self.swift_client).put_container(container_name)
        } unless container_exists?(swift_client: swift_client)
        @container_initialized = true
      end
    end

    def generate_uid(name)
      "#{Time.now.strftime '%Y/%m/%d/%H/%M/%S'}/#{SecureRandom.uuid}/#{name}"
    end

    def full_path(uid)
      File.join *[root_path, URI.escape(uid)].compact
    end

    def auth_url
      auth_url = openstack_options[:auth_url].gsub('auth/tokens', '').chomp('/')
      auth_url = "#{auth_url}/v3" unless auth_url.end_with?('/v3')
      auth_url
    end

    def swift_client_options #See https://github.com/mrkamel/swift_client
      options = {
        :auth_url => auth_url,
        :username => openstack_options.fetch(:username),
        # :user_id => credentials['userId'],
        :password => openstack_options.fetch(:password) { openstack_options.fetch(:api_key) },
        :user_domain_id => openstack_options.fetch(:domain_id),
        :storage_url => openstack_options.fetch(:storage_url),
        :temp_url_key => openstack_options.fetch(:temp_url_key)
      }
      options[:cache_store] = openstack_options[:cache_store] if openstack_options[:cache_store]
      # Dragonfly.debug "#{container_name} options: #{options.inspect}"

      options
    end

    def full_storage_headers(headers, meta)
      storage_headers.merge(meta_to_headers(meta)).merge(headers)
    end

    def headers_to_meta(headers)
      json = headers['x-openstack-meta-json']
      if json && !json.empty?
        unescape_meta_values(Serializer.json_decode(json))
      elsif marshal_data = headers['x-openstack-meta-extra']
        Utils.stringify_keys(Serializer.marshal_b64_decode(marshal_data))
      end
    end

    def meta_to_headers(meta)
      meta = escape_meta_values(meta)
      {'x-openstack-meta-json' => Serializer.json_encode(meta)}
    end

    # SwiftClient will automatically reconnect in case the endpoint responds with 401 Unauthorized to one of your requests
    # using the provided credentials. In case the endpoint does not respond with 2xx to any of SwiftClient's requests,
    # SwiftClient will raise a SwiftClient::ResponseError. Otherwise,
    # SwiftClient responds with an HTTParty::Response object,
    # such that you can call #headers to access the response headers
    # or #body as well as #parsed_response to access the response body and JSON response.
    # Checkout the HTTParty gem to learn more
    def rescuing_socket_errors(&block)
      yield
    # rescue Excon::Errors::SocketError => e
    #   storage.reload
    #   @container = nil
    #   yield
    end

    def escape_meta_values(meta)
      meta.inject({}) {|hash, (key, value)|
        hash[key] = value.is_a?(String) ? CGI.escape(value) : value
        hash
      }
    end

    def unescape_meta_values(meta)
      meta.inject({}) {|hash, (key, value)|
        hash[key] = value.is_a?(String) ? CGI.unescape(value) : value
        hash
      }
    end

  end
end

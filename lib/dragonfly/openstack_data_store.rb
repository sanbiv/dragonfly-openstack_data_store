require 'fog/openstack' #see https://github.com/fog/fog/blob/master/lib/fog/openstack/docs/storage.md
require 'dragonfly'
require 'cgi'
require 'uri'
require 'securerandom'

Dragonfly::App.register_datastore(:openstack_swift){ Dragonfly::OpenStackDataStore }

module Dragonfly
  class OpenStackDataStore

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

      @fog_storage_options = opts[:fog_storage_options] || {}
      @openstack_options   = opts[:openstack].inject({}) do |memo, item|
        key, value = item
        memo[:"openstack_#{key}"] = value
        memo
      end
      @default_expires_in = @openstack_options.delete(:openstack_temp_url_expires_in).to_i.nonzero? || 3600

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
      rescuing_socket_errors do
        #content.data....
        content.file do |f|
          container.files.create({
                                     :key           => full_path(uid),
                                     :body          => f,
                                     :content_type  => content.mime_type,
                                     :metadata      => full_storage_headers(headers, content.meta),
                                     :access_control_allow_origin => access_control_allow_origin
                                 })
        end
      end

      uid
    end

    def read(uid)
      file = rescuing_socket_errors{ container.files.get(full_path(uid)) }
      raise Excon::Errors::NotFound.new("#{uid} not found") unless file
      [
          file.body,                      # can be a String, File, Pathname, Tempfile
          headers_to_meta(file.metadata)  # the same meta Hash that was stored with write
      ]
    rescue Excon::Errors::NotFound => e
      Dragonfly.warn("#{self.class.name} read error: #{e}")
      nil # return nil if not found
    end

    def destroy(uid)
      rescuing_socket_errors do
        Thread.new do
          begin
            file = container.files.get(full_path(uid))
            raise Excon::Errors::NotFound.new("#{full_path(uid)} doesn't exist") unless file
            file.destroy
          rescue Excon::Errors::NotFound, Excon::Errors::Conflict => e
            Dragonfly.warn("#{self.class.name} destroy error: #{e}")
          end
        end

        # Thread.new do
        #   begin
        #     object_key = full_path(uid)
        #     Dragonfly.info("Deleting object #{object_key} inside #{container.key} with Thread (pid: #{Process.pid}")
        #     storage.delete_object(container.key, object_key)
        #   rescue => e
        #     Dragonfly.warn("#{object_key} doesn't exist, can't delete object: #{e.inspect}")
        #     raise Excon::Errors::NotFound.new("#{object_key} doesn't exist")
        #   end
        # end.join
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
      url = storage.send(method, container_name, file_key, expires_at, opts)
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

    def storage
      @storage ||= begin
        retry_times = 0
        begin
          fog_storage = ::Fog::Storage.new(full_storage_options)
          retry_times = 0
        rescue => e
          Dragonfly.warn("#{e.class}: #{e.message} (#{retry_times < 10 ? ' RETRYING' : ''})")
          retry if retry_times < 10
        ensure
          retry_times += 1
        end
        if @openstack_options[:openstack_temp_url_key] && set_meta_temp_url_key_on_startup?
          set_meta_temp_url_key!(storage_instance: fog_storage)
        end
        fog_storage
      end

      @storage
    end

    def set_meta_temp_url_key!(key = nil, force = false, storage_instance: nil)
      return true if @_meta_temp_url_key_sent && !force
      key ||= @openstack_options[:openstack_temp_url_key]
      if key
        begin
          storage_instance ||= storage
          storage_instance.post_set_meta_temp_url_key(@openstack_options[:openstack_temp_url_key])
          # request(
          #     :expects  => [201, 202, 204],
          #     :method   => 'POST',
          #     :headers  => {
          #         'X-Account-Meta-Temp-Url-Key' => @openstack_options[:openstack_temp_url_key],
          #         'X-Container-Meta-Access-Control-Allow-Origin' => '*'
          #     }
          # )

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

    def container
      ensure_container_initialized
      @container ||= begin
        rescuing_socket_errors{ storage.directories.get(container_name) }
      end
    end

    def container_exists?
      !rescuing_socket_errors{ storage.directories.get(container_name) }.nil?
    rescue Excon::Errors::NotFound => e
      false
    end

    private

    def ensure_container_initialized
      unless @container_initialized
        rescuing_socket_errors{ storage.directories.create(:key => container_name) } unless container_exists?
        @container_initialized = true
      end
    end

    def generate_uid(name)
      "#{Time.now.strftime '%Y/%m/%d/%H/%M/%S'}/#{SecureRandom.uuid}/#{name}"
    end

    def full_path(uid)
      File.join *[root_path, uid].compact
    end

    def full_storage_options
      openstack_options.merge(fog_storage_options.merge({:provider => 'OpenStack'}).
                                  reject { |_name, value| value.nil? })
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

    def rescuing_socket_errors(&block)
      yield
    rescue Excon::Errors::SocketError => e
      storage.reload
      @container = nil
      yield
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

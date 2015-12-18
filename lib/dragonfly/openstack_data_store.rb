require 'fog/openstack' #see https://github.com/fog/fog/blob/master/lib/fog/openstack/docs/storage.md
require 'dragonfly'
require 'cgi'
require 'securerandom'

Dragonfly::App.register_datastore(:openstack_swift){ Dragonfly::OpenStackDataStore }

module Dragonfly
  class OpenStackDataStore

    # Exceptions
    #class NotConfigured < RuntimeError; end

    attr_accessor :container_name,
                  :fog_storage_options, :openstack_options, :storage_headers,
                  :access_control_allow_origin,
                  :url_scheme, :url_host, :root_path

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

      @environment = opts.delete(:environment)
      @container_name = opts[:container] || "dragonfly-system-#{environment}"
      @fog_storage_options = opts[:fog_storage_options] || {}
      @openstack_options = opts[:openstack].inject({}) do |memo, item|
        key, value = item
        memo[:"openstack_#{key}"] = value
        memo
      end

      @access_control_allow_origin = opts[:access_control_allow_origin] || '*'

      @storage_headers = opts[:storage_headers] || {}
      @url_scheme = opts[:url_scheme] || 'http'
      @url_host = opts[:url_host]
      @root_path = opts[:root_path]
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
      raise Excon::Errors::NotFound unless file
      [
          file.body,                      # can be a String, File, Pathname, Tempfile
          headers_to_meta(file.metadata)  # the same meta Hash that was stored with write
      ]
    rescue Excon::Errors::NotFound => e
      nil # return nil if not found
    end

    def destroy(uid)
      rescuing_socket_errors do
        file = container.files.get(full_path(uid))
        raise Excon::Errors::NotFound.new("#{full_path(uid)} doesn't exist") unless file
        file.destroy
      end
    rescue Excon::Errors::NotFound, Excon::Errors::Conflict => e
      Dragonfly.warn("#{self.class.name} destroy error: #{e}")
    end

    def url_for(uid, opts={})
      file = container.get(full_path(uid))
      return nil unless file
      file.public_url
      # URI::HTTP.build(scheme: options[:scheme] || connection.connection.service_scheme,
      #                 host: storage.connection.service_host,
      #                 path: "#{storage.connection.service_path}/#{file.directory.key}/#{file.key}").to_s
      # if expires = opts[:expires]
      #   storage.get_object_https_url(container_name, full_path(uid), expires, {:query => opts[:query]})
      # else
      #   scheme = opts[:scheme] || url_scheme
      #   host   = opts[:host]   || url_host || (
      #     container_name =~ SUBDOMAIN_PATTERN ? "#{container_name}.s3.amazonaws.com" : "s3.amazonaws.com/#{container_name}"
      #   )
      #   "#{scheme}://#{host}/#{full_path(uid)}"
      # end
    end

    def storage
      @storage ||= begin
        storage = Fog::Storage.new(full_storage_options)
        storage
      end
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

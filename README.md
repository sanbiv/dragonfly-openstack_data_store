# Dragonfly::OpenStackDataStore

OpenStack Swift data store for use with the [Dragonfly](http://github.com/markevans/dragonfly) gem.

Based on:

* [dragonfly-s3_data_store version](https://github.com/markevans/dragonfly-s3_data_store) 1.2
* [Fog](https://github.com/fog/fog)
* [Fog::OpenStack](https://github.com/fog/fog/blob/master/lib/fog/openstack/docs/getting_started.md)

However this does not affect any functionality and won't break any of your old content!
It's just more robust.

## Gemfile

```ruby
gem 'dragonfly-openstack_data_store', '~> 1.0.3', git: 'https://github.com/sanbiv/dragonfly-openstack_data_store'
```

## Usage
Configuration (remember the require)

```ruby
require 'dragonfly/openstack_data_store'

Dragonfly.app.configure do
  # ...

  datastore :openstack_swift,
    container: "my-dragonfly-container-#{ENV['RACK_ENV'] || ENV['RAILS_ENV'] || 'development'}",
    access_control_allow_origin: '*',
    openstack: {
      auth_url: 'https://identity.open.softlayer.com/v2.0/tokens',
      api_key: 'abvd1234',
      username: 'user_xxx'
    }

  # ...
end
```

### Available configuration options

```ruby
:container
:openstack            #See https://github.com/fog/fog/blob/master/lib/fog/openstack/docs/getting_started.md
:storage_headers      # defaults to {}, can be overridden per-write - see below
:fog_storage_options  # hash for passing any extra options to Fog::Storage.new, e.g. {path_style: true}
```

### IBM Bluemix Object Storage

After creating Bluemix service, you get credentials like this:

```javascript
  {
     "credentials": {
         "auth_url": "https://identity.open.softlayer.com",
         "project": "object_storage_xxxxxxxx",
         "projectId": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
         "region": "dallas",
         "userId": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
         "username": "user_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
         "password": "xxxxxxxxxxxxxxx",
         "domainId": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
         "domainName": "xxxxxx"
     }
  }
```
This is the configuration you should use for Dragonfly::OpenStackDataStore

```ruby
Dragonfly.app.configure do
  # ...

  datastore :openstack_swift,
    container: "my-container",
    #access_control_allow_origin: '*',
    openstack: {
      auth_url: "#{credentials['auth_url']}/v3/auth/tokens", #https://identity.open.softlayer.com/v3/auth/tokens
      api_key: credentials['password'],
      username: credentials['username'],
      project_id: credentials['projectId'],
      region: credentials['region'],
      #set domain_name
      domain_name: credentials['domainName']
      #or...user_id (this will make a different auth request and domain_name will ignored)
      user_id: credentials['userId']
    }

  # ...
end
```


### Per-storage options
```ruby
Dragonfly.app.store(some_file, {'some' => 'metadata'}, path: 'some/path.txt', headers: {'x-acl' => 'public-read-write'})
```

or

```ruby
class MyModel
  dragonfly_accessor :photo do
    storage_options do |attachment|
      {
        path: "some/path/#{some_instance_method}/#{rand(100)}",
        headers: {"x-acl" => "public-read-write"}
      }
    end
  end
end
```

**BEWARE!!!!** you must make sure the path (which will become the uid for the content) is unique and changes each time the content
is changed, otherwise you could have caching problems, as the generated urls will be the same for the same uid.

### Serving directly from OpenStack Swift

You can get the OpenStack Swift url using

```ruby
Dragonfly.app.remote_url_for('some/uid')
```

or

```ruby
my_model.attachment.remote_url
```

or with an expiring url:

```ruby
my_model.attachment.remote_url
```

## TODO
* [ ] write test

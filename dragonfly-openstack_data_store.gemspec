# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'dragonfly/openstack_data_store/version'

Gem::Specification.new do |spec|
  spec.name          = "dragonfly-openstack_data_store"
  spec.version       = Dragonfly::OpenStackDataStore::VERSION
  spec.authors       = ["Santi Bivacqua"]
  spec.email         = ["info@miserve.com"]
  spec.description   = %q{OpenStack data store for Dragonfly (IBM BlueMix compatible)}
  spec.summary       = %q{Data store for storing Dragonfly content (e.g. images) on OpenStack Swift (also on IBM BlueMix)}
  spec.homepage      = "https://github.com/sanbiv/dragonfly-openstack_data_store"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency 'dragonfly', '~> 1.0'
  spec.add_runtime_dependency "mime-types", '>= 2.0', '< 3.0'
  spec.add_dependency "fog-openstack", '~> 0.1.1'
  spec.add_development_dependency 'rspec', '~> 2.0'

  spec.post_install_message = <<-POST_INSTALL_MESSAGE
=====================================================
Thanks for installing dragonfly-openstack_data_store!!
=====================================================
POST_INSTALL_MESSAGE
end

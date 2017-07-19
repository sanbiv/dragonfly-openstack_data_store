require 'dragonfly/spec/data_store_examples'
require 'yaml'
require 'dragonfly/openstack_data_store'

RSpec.configure do |config|
  config.treat_symbols_as_metadata_keys_with_true_values = true
  config.run_all_when_everything_filtered = true
  config.filter_run :focus
  config.order = 'random'
end


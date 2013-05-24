package node[:mongodb][:package_name] do
  action :install
end

# install the mongo ruby gem at compile time to make it globally available
gem_package 'mongo' do
  version "1.8.5"
  action :nothing
end.run_action(:install)
Gem.clear_paths
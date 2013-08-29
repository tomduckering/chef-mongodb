if ! node[:mongodb][:omit_repos]
  include_recipe "mongodb::10gen_repo"
end

package node['mongodb']['package_name'] do
  action :install
end

# install the mongo ruby gem at compile time to make it globally available
chef_gem 'mongo' do
  version "1.8.5"
  action :nothing
end

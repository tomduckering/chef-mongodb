include_recipe "mongodb::10gen_repo" unless node['mongodb']["omit_repos"]

package node['mongodb']['package_name'] do
  action :install
end

# install the mongo ruby gem at compile time to make it globally available
chef_gem 'mongo' do
  version "1.8.5"
  action :nothing
end

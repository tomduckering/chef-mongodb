if node['mongodb']['install_method'] == 'package'
  include_recipe 'mongodb::10gen_repo'
elsif node['mongodb']['install_method'] == 'file'
  
  remote_file "#{Chef::Config[:file_cache_path]}/#{node['mongodb']['package_name']}" do
    source node['mongodb']['package_url']
    mode 0644
  end

else
  Chef::log.fatal("Unknown install method specified #{node['mongodb']['install_method']} - only package or file")
end

package node['mongodb']['package_name'] do
  action :install
  if node['mongodb']['install_method'] == 'file'
    source "#{Chef::Config[:file_cache_path]}/#{node['mongodb']['package_name']}"
  end
end

# install the mongo ruby gem at compile time to make it globally available
gem_package 'mongo' do
  version "1.8.5"
  action :nothing
end.run_action(:install)
Gem.clear_paths

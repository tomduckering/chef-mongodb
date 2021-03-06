#
# Cookbook Name:: mongodb
# Definition:: mongodb
#
# Copyright 2011, edelight GmbH
# Authors:
#       Markus Korn <markus.korn@edelight.de>
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'json'

@running_under_chef = (defined?(Chef) == 'constant')



class Chef::ResourceDefinitionList::MongoDB
#class Tom

  def self.log(level,message)
    puts ("#{level}: #{message}")
  end
  private_class_method :log

  def self.info(message)
    log("info",message) unless @running_under_chef
    Chef::Log.info(message) if @running_under_chef
  end
    private_class_method :info

  def self.warn(message)
    log("warn",message) unless @running_under_chef
    Chef::Log.warn(message) if @running_under_chef
  end
  
    private_class_method :warn

  def self.error(message)
    log("error",message) unless @running_under_chef
    Chef::Log.error(message) if @running_under_chef
  end
  
    private_class_method :error

  def self.fatal(message)
    log("fatal",message) unless @running_under_chef
    Chef::Log.fatal(message) if @running_under_chef
  end
  
    private_class_method :fatal
  

  def self.create_new_replica_set_config(current_config,new_member_hostnames)
    new_config = {}

    new_config['_id']     = current_config['_id']    
    new_config['version'] = current_config['version'] + 1
    new_config['members'] = []

    highest_current_member_id = current_config['members'].collect{|member| member['_id'].to_i}.max

    next_new_id = highest_current_member_id + 1

    new_member_hostnames.each_with_index do |hostname,index|

      #see if the hostname already exists in the config and use that existing id.
      matched_members = current_config['members'].select{|member| member['host'] == hostname}

      if matched_members.length == 1
        new_config['members'] << matched_members[0]
      elsif matched_members.length > 1
        #something went really wrong. Config shouldn't have more than once of the same instance.
      else
        #not an existing member
        new_config['members'] << {"_id" => next_new_id, 'host' => hostname}
        next_new_id = next_new_id + 1
      end
    end

    return new_config
  end
  
  private_class_method :create_new_replica_set_config

  def self.check_members(members)
    if members.length == 0
      if @running_under_chef and Chef::Config[:solo]
        abort("Cannot configure replicaset '#{name}', no member nodes found")
      else
        warn "Cannot configure replicaset '#{name}', no member nodes found"
        return
      end
    end
  end
  
    private_class_method :check_members

  def self.normalise_members(members,node)
    members << node unless members.include?(node) #This line doesn't seem to work
    members = members.sort{ |x,y| x['fqdn'] <=> y['fqdn'] }
    members = members.uniq{ |x| x['fqdn'] }
  end
  
    private_class_method :normalise_members

  def self.build_replica_set_config(name,members)
    replica_set_config = { '_id' => name, 'members' => [] }
    members.each_with_index do |member,index|
      replica_set_config['members'] << { '_id' => index, 'host' => "#{member['fqdn']}:#{member['mongodb']['port']}"}
    end
    replica_set_config
  end
  
  private_class_method :build_replica_set_config
  

  def self.get_member_list(replica_set_config)
    replica_set_config['members'].map{|m| m['host']}
  end
  
  private_class_method :get_member_list
  

  def self.build_replica_set_command(command,replica_set_config)
    replica_set_initiate_command = BSON::OrderedHash.new
    replica_set_initiate_command[command] = replica_set_config
    replica_set_initiate_command
  end
  
  private_class_method :build_replica_set_command
  
  def self.configure_replicaset(node, name, other_members)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'
    
    this_node_mongo_port = node['mongodb']['port']
    
    check_members(other_members)
    
    all_members                  = normalise_members(other_members,node)
    intended_replica_set_config  = build_replica_set_config(name,all_members)
    intended_members             = get_member_list(intended_replica_set_config)
    members_without_current_host = intended_members.reject{|member| member == "#{node['fqdn']}:#{node['mongodb']['port']}"}
    replica_set_initiate_command = build_replica_set_command('replSetInitiate',intended_replica_set_config)    

    begin
      local_mongo_client = Mongo::MongoClient.new('localhost', this_node_mongo_port,:slave_ok => true, :connect_timeout => 30, :op_timeout => 30)
    rescue
      warn "Could not connect to database: 'localhost:#{this_node_mongo_port}'"
      return
    end

    local_admin_collection = local_mongo_client['admin']
    
    info "Sending the following command: #{replica_set_initiate_command.inspect}"

    begin
      replicaset_initiate_result = local_admin_collection.command(replica_set_initiate_command, :check_response => false)
    rescue Mongo::OperationTimeout
      info "Started configuring the replicaset, this will take some time, another run should run smoothly"
      return
    end
    
    info replicaset_initiate_result.inspect

    already_initialized             = /already initialized/
    already_initiated               = /couldn't initiate : member ([a-zA-Z0-9\-_]*):(\d*) is already initiated/

    if replicaset_initiate_result['errmsg'] =~ already_initialized or replicaset_initiate_result['errmsg'] =~ already_initiated

      info 'Replica set is already initialized - though it might not be configured as we want...'

      #current_replica_set_config = local_mongo_client['local']['system']['replset'].find_one({"_id" => name})
      
      #if nil? current_local_replic
      #  info "No local replica set config..."
      
      #end
      
      info "Connecting to replica set: #{members_without_current_host}..."
      
      begin
        replica_set_client = Mongo::MongoReplicaSetClient.new(intended_members, :refresh_mode => :sync,:connect_timeout => 30, :op_timeout => 30)
      rescue Exception => e  
        warn e.message
        warn "Could not connect to replica set: '#{intended_members}'"
        return
      end
      
      current_replica_set_config = replica_set_client['local']['system']['replset'].find_one({"_id" => name})
      
      replica_set_admin_collection = replica_set_client['admin']
      
      current_members  = get_member_list(current_replica_set_config)
      
      #Compare config based on membership
      if current_members != intended_members 
        
        info 'Set of intended members does not match current set.'
        
        members_to_remove = current_members  - intended_members 
        members_to_add    = intended_members - current_members
        members_remaining = current_members & intended_members

        info "Members to add :             #{members_to_add}"
        info "Members to remove :          #{members_to_remove}"
        info "Remaining original members : #{members_remaining}"

        #replica_set_client = Mongo::MongoReplicaSetClient.new(members_remaining, :refresh_mode => :sync,:connect_timeout => 30, :op_timeout => 30)

        
        intended_replica_set_config = create_new_replica_set_config(current_replica_set_config,intended_members)
        
        info "Re-configuring with the following doc : #{intended_replica_set_config.inspect}"
        
        replica_set_reconfig_command = build_replica_set_command('replSetReconfig',intended_replica_set_config)
        
        rs_reconfigure_result = replica_set_admin_collection.command(replica_set_reconfig_command,:check_response => false)
        
        info rs_reconfigure_result.inspect
      else
        info "Replica set configuration is as it should be."
      
      end

    end
    
    couldnt_initiate_need_all_members = /couldn't initiate : need all members up to initiate, not ok : ([a-zA-Z0-9\-_]*):(\d*)/
    couldnt_initiate_cant_find_self = /couldn't initiate : can't find self in the replset config/
    
    if replicaset_initiate_result['errmsg'] =~ couldnt_initiate_need_all_members or
       replicaset_initiate_result['errmsg'] =~ couldnt_initiate_cant_find_self

      missing_member_host = $1
      missing_member_port = $2.to_i      
      
      error "Other members of the replica set do not seem to be available: #{missing_member_host}:#{missing_member_port}"
    
    end


=begin
    already_initiated = /couldn't initiate : member ([a-zA-Z0-9\-_]*):(\d*) is already initiated/
    if replicaset_initiate_result['errmsg'] =~ already_initiated

      existing_member_host = $1
      existing_member_port = $2.to_i

      replica_set_client = Mongo::MongoReplicaSetClient.new(["#{existing_member_host}:#{existing_member_port}"])

      replica_set_admin_collection = replica_set_client['admin']

      current_replica_set_config = replica_set_client['local']['system']['replset'].find_one({"_id" => name})

      
      intended_replica_set_config = create_new_replica_set_config(current_replica_set_config,intended_members)

      replica_set_reconfig_command = BSON::OrderedHash.new
      replica_set_reconfig_command['replSetReconfig'] = intended_replica_set_config

      rs_reconfigure_result = replica_set_admin_collection.command(replica_set_reconfig_command,:check_response => false)
      info rs_reconfigure_result.inspect
    end
=end
  end

=begin
    info " Configuring replicaset with members #{members.collect{ |n| n['hostname'] }.join(', ')}")    
    
    begin
      connection = Mongo::Connection.new('localhost', this_node_mongo_port, :op_timeout => 5, :slave_ok => true)
    rescue
      warn "Could not connect to database: 'localhost:#{this_node_mongo_port}'")
      return
    end
    
    rs_members = []
    rs_member_ips = []
    
    members.each_with_index do |member,n|
      port = member['mongodb']['port']
      rs_members << {"_id" => n, "host" => "#{member['fqdn']}:#{port}"}
      rs_member_ips << {"_id" => n, "host" => "#{member['ipaddress']}:#{port}"}
    end
    
    admin = connection['admin']
    cmd = BSON::OrderedHash.new
    cmd['replSetInitiate'] = {
        "_id" => name,
        "members" => rs_members
    }
    
    begin
      result = admin.command(cmd, :check_response => false)
    rescue Mongo::OperationTimeout
      info "Started configuring the replicaset, this will take some time, another run should run smoothly")
      return
    end
    
    #check ok is 1 which means we're all good.
    if result['ok'] == 1
      # everything is fine, do nothing
    
    #if we get "already initialised then let's check some things out."
    elsif result['errmsg'].include?("already init")
      
      # check if both configs are the same
      
      #grab localhost's replicaset config.
      localhost_replicaset_config = connection['local']['system']['replset'].find_one({"_id" => name})
      
      if !nil?(localhost_replicaset_config) and localhost_replicaset_config['_id'] == name and localhost_replicaset_config['members'] == rs_members
        # config is up-to-date, do nothing
        info "Replicaset '#{name}' already configured")
        
        
      elsif !nil?(localhost_replicaset_config) and localhost_replicaset_config['_id'] == name and localhost_replicaset_config['members'] == rs_member_ips
        # config is up-to-date, but ips are used instead of hostnames, change config to hostnames
        info "Need to convert ips to hostnames for replicaset '#{name}'")
        old_members = localhost_replicaset_config['members'].collect{ |m| m['host'] }
        
        mapping = {}
        rs_member_ips.each do |mem_h|
          members.each do |n|
            ip, prt = mem_h['host'].split(":")
            if ip == n['ipaddress']
              mapping["#{ip}:#{prt}"] = "#{n['fqdn']}:#{prt}"
            end
          end
        end
        
        
        localhost_replicaset_config['members'].collect!{ |m| {"_id" => m["_id"], "host" => mapping[m["host"]]} }
        localhost_replicaset_config['version'] += 1
        
        rs_connection = Mongo::ReplSetConnection.new( *old_members.collect{ |m| m.split(":") })
        admin = rs_connection['admin']
        cmd = BSON::OrderedHash.new
        cmd['replSetReconfig'] = localhost_replicaset_config
        result = nil
        
        begin
          result = admin.command(cmd, :check_response => false)
        rescue Mongo::ConnectionFailure
          # reconfiguring destroys exisiting connections, reconnect
          Mongo::Connection.new('localhost', node['mongodb']['port'], :op_timeout => 5, :slave_ok => true)
          localhost_replicaset_config = connection['local']['system']['replset'].find_one({"_id" => name})
          info " New config successfully applied: #{localhost_replicaset_config.inspect}")
        end
        
        if !result.nil?
          error " configuring replicaset returned: #{result.inspect}")
        end
        
      else
        #There's a change to the replica set members (adding and/or removing)
        
        # remove removed members from the replicaset and add the new ones
        
        max_id = localhost_replicaset_config['members'].collect{ |member| member['_id']}.max
        
        rs_members.collect!{ |member| member['host'] }
        localhost_replicaset_config['version'] += 1
        old_members = localhost_replicaset_config['members'].collect{ |member| member['host'] }
        members_delete = old_members - rs_members        
        localhost_replicaset_config['members'] = localhost_replicaset_config['members'].delete_if{ |m| members_delete.include?(m['host']) }
        members_add = rs_members - old_members
        members_add.each do |m|
          max_id += 1
          config['members'] << {"_id" => max_id, "host" => m}
        end
        
        debug(old_members)
        .debug(old_members.collect{ |m| m.split(":") }.to_s)
        
        rs_connection = Mongo::MongoReplicaSetClient.new( old_members )
        admin = rs_connection['admin']
        
        cmd = BSON::OrderedHash.new
        cmd['replSetReconfig'] = localhost_replicaset_config
        
        result = nil
        begin
          result = admin.command(cmd, :check_response => false)
        rescue Mongo::ConnectionFailure
          # reconfiguring destroys exisiting connections, reconnect
          Mongo::Connection.new('localhost', node['mongodb']['port'], :op_timeout => 5, :slave_ok => true)
          config = connection['local']['system']['replset'].find_one({"_id" => name})
          info " New config successfully applied: #{config.inspect}")
        end
        if !result.nil?
          error " configuring replicaset returned: #{result.inspect}")
        end
      end
    elsif !result.fetch("errmsg", nil).nil?
      error " Failed to configure replicaset, reason: #{result.inspect}")
    end
=end
  
  def self.configure_shards(node, shard_nodes)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'
    
    shard_groups = Hash.new{|h,k| h[k] = []}
    
    shard_nodes.each do |n|
      if n['recipes'].include?('mongodb::replicaset')
        key = "rs_#{n['mongodb']['shard_name']}"
      else
        key = '_single'
      end
      shard_groups[key] << "#{n['fqdn']}:#{n['mongodb']['port']}"
    end
    info(shard_groups.inspect)
    
    shard_members = []
    shard_groups.each do |name, members|
      if name == "_single"
        shard_members += members
      else
        shard_members << "#{name}/#{members.join(',')}"
      end
    end
    #info(shard_members.inspect)
    
    begin
      connection = Mongo::Connection.new('localhost', node['mongodb']['port'], :op_timeout => 5)
    rescue Exception => e
      warn "Could not connect to database: 'localhost:#{node['mongodb']['port']}', reason #{e}"
      return
    end
    
    admin = connection['admin']
    
    shard_members.each do |shard|
      cmd = BSON::OrderedHash.new
      cmd['addShard'] = shard
      begin
        result = admin.command(cmd, :check_response => false)
      rescue Mongo::OperationTimeout
        result = "Adding shard '#{shard}' timed out, run the recipe again to check the result"
      end
      #info(result.inspect)
      
    end
  end
  
  def self.configure_sharded_collections(node, sharded_collections)
    # lazy require, to move loading this modules to runtime of the cookbook
    require 'rubygems'
    require 'mongo'
    
    begin
      connection = Mongo::Connection.new('localhost', node['mongodb']['port'], :op_timeout => 5)
    rescue Exception => e
      warn "Could not connect to database: 'localhost:#{node['mongodb']['port']}', reason #{e}"
      return
    end
    
    admin = connection['admin']
    
    databases = sharded_collections.keys.collect{ |x| x.split(".").first}.uniq
    info "enable sharding for these databases: '#{databases.inspect}'"
    
    databases.each do |db_name|
      cmd = BSON::OrderedHash.new
      cmd['enablesharding'] = db_name
      begin
        result = admin.command(cmd, :check_response => false)
      rescue Mongo::OperationTimeout
        result = "enable sharding for '#{db_name}' timed out, run the recipe again to check the result"
      end
      if result['ok'] == 0
        # some error
        errmsg = result.fetch("errmsg")
        if errmsg == "already enabled"
          info "Sharding is already enabled for database '#{db_name}', doing nothing"
        else
          error "Failed to enable sharding for database #{db_name}, result was: #{result.inspect}"
        end
      else
        # success
        info "Enabled sharding for database '#{db_name}'"
      end
    end
    
    sharded_collections.each do |name, key|
      cmd = BSON::OrderedHash.new
      cmd['shardcollection'] = name
      cmd['key'] = {key => 1}
      begin
        result = admin.command(cmd, :check_response => false)
      rescue Mongo::OperationTimeout
        result = "sharding '#{name}' on key '#{key}' timed out, run the recipe again to check the result"
      end
      if result['ok'] == 0
        # some error
        errmsg = result.fetch("errmsg")
        if errmsg == "already sharded"
          info "Sharding is already configured for collection '#{name}', doing nothing"
        else
          error "Failed to shard collection #{name}, result was: #{result.inspect}"
        end
      else
        # success
        info "Sharding for collection '#{result['collectionsharded']}' enabled"
      end
    end
  
  end
  
end

#Tom.configure_replicaset(node, name, members)

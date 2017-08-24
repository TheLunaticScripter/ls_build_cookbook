#
# Cookbook:: ls_build_cookbook
# Recipe:: deploy
#
# Copyright:: 2017, The Authors, All Rights Reserved.
#include_recipe 'delivery-truck::deploy'

case workflow_stage

# Ensure the following actions only occur in the Delivered stage
when 'delivered'
  # Get vault data via BuildCookbook::Helper
  vault_data = get_workflow_vault_data

  # Iterate through Chef Servers
  vault_data['deploy']['chef_servers'].each do |server_info|
    # Set file paths inside project cache
    client_key_path = File.join(workflow_workspace_cache, 'delete_me.pem')
    knife_rb_path = File.join(workflow_workspace_cache, 'knife.rb')

    # Create key for Knife to use (gets overwritten by each deploy)
    file client_key_path do
      content server_info['key']
      sensitive true
      action :create
    end

    # Create knife.rb file (gets overwritten by each deploy)
    file knife_rb_path do
      # Set file content and strip leading white space
      content <<-EOF.gsub(/^\s+/, '')
        log_location             STDOUT
        node_name                "#{server_info['user']}"
        client_key               "#{client_key_path}"
        chef_server_url          "#{server_info['url']}"
        trusted_certs_dir        "/etc/chef/trusted_certs"
      EOF
      action :create
    end

    # Create the upload directory where cookbooks to be uploaded will be staged
    cookbook_vendor = File.join(workflow_workspace_cache, 'cookbook-vendor')
    directory cookbook_vendor do
      recursive true
      # We delete the cookbook upload staging directory each time to ensure we
      # don't have out-of-date cookbooks hanging around from a previous deploy.
      action [:delete, :create]
    end

    # Perform a `berks install` and set path to vendor directory
    execute "do berks install in #{workflow_change_project} cookbook" do
      command 'berks install'
      live_stream true
      environment BERKSHELF_PATH: cookbook_vendor
      cwd workflow_workspace_repo
    end

    # Perform a `berks upload` using the Knife config generated earlier
    execute "do berks upload in #{workflow_change_project} cookbook" do
      command 'berks upload'
      live_stream true
      environment(
        BERKSHELF_CHEF_CONFIG: knife_rb_path,
        BERKSHELF_PATH: cookbook_vendor
      )
      cwd workflow_workspace_repo
    end

    # Ensure keys are deleted after deploy is done
    [client_key_path, knife_rb_path].each do |file_path|
      file file_path do
        action :delete
      end
    end
  end
else
  def choose_transport(platform)
    case platform
    when 'windows'
      'winrm'
    else
      'ssh'
    end
  end

  def build_knife_command(transport, admin_username, admin_password, fqdn)
    <<-EOC.gsub(/^\s+/, '')
       knife #{transport} 'fqdn:#{fqdn}' 'chef-client' -x '#{admin_username}' -P #{admin_password}
    EOC
  end

  Chef::Config.from_file(automate_knife_rb)

  workflow_environment = workflow_chef_environment_for_stage
  workflow_project = workflow_change_project

  # Get a list of infrastructure nodes by environment and recipes in run_list
  infra_nodes = search(
    :node,
    "chef_environment:#{workflow_environment} AND recipes:#{workflow_project}",
    filter_result: {
      fqdn: ['fqdn'],
      platform: ['platform']
    }
  )

  if infra_nodes.empty?
    Chef::Log.warn("No nodes returned by search: chef_environment:#{workflow_environment} AND recipes:#{workflow_project}")
  else
    vault_data = get_workflow_vault_data
    infra_nodes.each do |infra_node|
      transport = choose_transport(infra_node['platform'])
      knife_command = build_knife_command(
        transport,
        vault_data['smoke']['inspec']['admin_username'],
        vault_data['smoke']['inspec']['admin_password'],
        infra_node['fqdn']
      )

      execute "run chef-client on #{infra_node['fqdn']}" do
        command knife_command
        cwd delivery_workspace_repo
        sensitive true
        action :run
      end
    end
  end
end

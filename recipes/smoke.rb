#
# Cookbook:: ls_build_cookbook
# Recipe:: smoke
#
# Copyright:: 2017, The Authors, All Rights Reserved.
include_recipe 'delivery-truck::smoke'

def choose_transport(platform)
  case platform
  when 'windows'
    'winrm'
  else
    'ssh'
  end
end

def build_inspec_command(transport, admin_username, admin_password, fqdn)
  <<-EOC.gsub(/^\s+/, '')
    inspec exec test/smoke/default/ -b #{transport} --host=#{fqdn} --user='#{admin_username}' --password='#{admin_password}'
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
    platform: ['platform'],
  }
)

if infra_nodes.empty?
  Chef::Log.warn("No nodes returned by search: chef_environment:#{workflow_environment} AND recipes:#{workflow_project}")
else
  vault_data = get_workflow_vault_data
  infra_nodes.each do |infra_node|
    transport = choose_transport(infra_node['platform'])
    inspec_command = build_inspec_command(
      transport,
      vault_data['smoke']['inspec']['admin_username'],
      vault_data['smoke']['inspec']['admin_password'],
      infra_node['fqdn']
    )

    execute "run smoke tests on #{infra_node['fqdn']}" do
      command inspec_command
      cwd delivery_workspace_repo
      sensitive true
      action :run
    end
  end
end

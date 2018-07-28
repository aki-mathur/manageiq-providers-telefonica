require 'manageiq/providers/telefonica/legacy/telefonica_configuration_parser'

class ManageIQ::Providers::Telefonica::InfraManager::Host < ::Host
  include ManageIQ::Providers::Telefonica::HelperMethods
  belongs_to :availability_zone

  has_many :host_service_group_telefonicas, :foreign_key => :host_id, :dependent => :destroy,
    :class_name => 'ManageIQ::Providers::Telefonica::InfraManager::HostServiceGroup'

  has_many :network_ports, :as => :device
  has_many :network_routers, :through => :cloud_subnets
  has_many :cloud_networks, :through => :cloud_subnets
  alias_method :private_networks, :cloud_networks
  has_many :cloud_subnets, :through    => :network_ports
  has_many :public_networks, :through => :cloud_subnets

  has_many :floating_ips, :through => :network_ports

  include_concern 'Operations'

  supports :refresh_network_interfaces

  # TODO(lsmola) for some reason UI can't handle joined table cause there is hardcoded somewhere that it selects
  # DISTINCT id, with joined tables, id needs to be prefixed with table name. When this is figured out, replace
  # cloud tenant with rails relations
  # in /app/models/miq_report/search.rb:83 there is select(:id) by hard
  # has_many :vms, :class_name => 'ManageIQ::Providers::Telefonica::CloudManager::Vm', :foreign_key => :host_id
  # has_many :cloud_tenants, :through => :vms, :uniq => true

  def cloud_tenants
    ::CloudTenant.where(:id => vms.collect(&:cloud_tenant_id).uniq)
  end

  # TODO(aveselov) Added 3 empty methods here because 'entity' inside 'build_recursive_topology' calls for these methods.
  # Work still in progress, but at least it makes a topology visible for rhos undercloud.

  def load_balancers
  end

  def cloud_tenant
  end

  def security_groups
  end

  def ssh_users_and_passwords
    user_auth_key, auth_key = auth_user_keypair
    user_password, password = auth_user_pwd
    su_user, su_password = nil, nil

    # TODO(lsmola) make sudo user work with password. We will not probably support su, as root will not have password
    # allowed. Passwordless sudo is good enough for now

    if !user_auth_key.blank? && !auth_key.blank?
      passwordless_sudo = user_auth_key != 'root'
      return user_auth_key, nil, su_user, su_password, {:key_data => auth_key, :passwordless_sudo => passwordless_sudo}
    else
      passwordless_sudo = user_password != 'root'
      return user_password, password, su_user, su_password, {:passwordless_sudo => passwordless_sudo}
    end
  end

  def get_parent_keypair(type = nil)
    # Get private key defined on Provider level, in the case all hosts has the same user
    ext_management_system.try(:authentication_type, type)
  end

  def authentication_best_fit(requested_type = nil)
    [requested_type, :ssh_keypair, :default].compact.uniq.each do |type|
      auth = authentication_type(type)
      return auth if auth && auth.available?
    end
    # If auth is not defined on this specific host, get auth defined for all hosts from the parent provider.
    get_parent_keypair(:ssh_keypair)
  end

  def authentication_status
    if !authentication_type(:ssh_keypair).try(:auth_key).blank?
      authentication_type(:ssh_keypair).status
    elsif !authentication_type(:default).try(:password).blank?
      authentication_type(:default).status
    else
      # If credentials are not on host's auth, we use host's ssh_keypair as a placeholder for status
      authentication_type(:ssh_keypair).try(:status) || "None"
    end
  end

  def verify_credentials(auth_type = nil, options = {})
    raise MiqException::MiqHostError, "No credentials defined" if missing_credentials?(auth_type)
    raise MiqException::MiqHostError, "Logon to platform [#{os_image_name}] not supported" if auth_type.to_s != 'ipmi' && os_image_name !~ /linux_*/

    case auth_type.to_s
    when 'remote', 'default', 'ssh_keypair' then verify_credentials_with_ssh(auth_type, options)
    when 'ws'                               then verify_credentials_with_ws(auth_type)
    when 'ipmi'                             then verify_credentials_with_ipmi(auth_type)
    else
      verify_credentials_with_ws(auth_type)
    end

    true
  end

  def update_ssh_auth_status!
    # Creating just Auth status placeholder, the credentials are stored in parent or this auth, parent is
    # EmsTelefonicaInfra in this case. We will create Auth per Host where we will store state, if it not exists
    auth = authentication_type(:ssh_keypair) ||
           ManageIQ::Providers::Telefonica::InfraManager::AuthKeyPair.create(
             :name          => "#{self.class.name} #{name}",
             :authtype      => :ssh_keypair,
             :resource_id   => id,
             :resource_type => 'Host')

    # If authentication is defined per host, use that
    best_fit_auth = authentication_best_fit
    auth = best_fit_auth if best_fit_auth && !parent_credentials?

    status, details = authentication_check_no_validation(auth.authtype, {})
    status == :valid ? auth.validation_successful : auth.validation_failed(status, details)
  end

  def missing_credentials?(type = nil)
    if type.to_s == "ssh_keypair"
      if !authentication_type(:ssh_keypair).try(:auth_key).blank?
        # Credential are defined on host
        !has_credentials?(type)
      else
        # Credentials are defined on parent ems
        get_parent_keypair(:ssh_keypair).try(:userid).blank?
      end
    else
      !has_credentials?(type)
    end
  end

  def parent_credentials?
    # Whether credentials are defined in parent or host. Missing credentials can be taken as parent.
    authentication_best_fit.try(:resource_type) != 'Host'
  end

  def refresh_telefonica_services(ssu)
    telefonica_status = ssu.shell_exec("systemctl -la --plain | awk '/telefonica/ {gsub(/ +/, \" \"); gsub(\".service\", \":\"); gsub(\"not-found\",\"(disabled)\"); split($0,s,\" \"); print s[1],s[3],s[2]}' | sed \"s/ loaded//g\"")
    services = MiqLinux::Utils.parse_telefonica_status(telefonica_status)
    self.host_service_group_telefonicas = services.map do |service|
      # find TelefonicaHostServiceGroup records by host and name and initialize if not found
      host_service_group_telefonicas.where(:name => service['name'])
        .first_or_initialize.tap do |host_service_group_telefonica|
        # find SystemService records by host
        # filter SystemService records by names from telefonica systemctl status results
        sys_services = system_services.where(:name => service['services'].map { |ser| ser['name'] })
        # associate SystemService record with TelefonicaHostServiceGroup
        host_service_group_telefonica.system_services = sys_services

        # find Filesystem records by host
        # filter Filesystem records by names
        # we assume that /etc/<service name>* is good enough pattern
        dir_name = "/etc/#{host_service_group_telefonica.name.downcase.gsub(/\sservice.*/, '')}"

        matcher = Filesystem.arel_table[:name].matches("#{dir_name}%")
        files = filesystems.where(matcher)
        host_service_group_telefonica.filesystems = files

        # save all changes
        host_service_group_telefonica.save
        # parse files into attributes
        refresh_custom_attributes_from_conf_files(files) unless files.blank?
      end
    end
  rescue => err
    _log.log_backtrace(err)
    raise err
  end

  def refresh_custom_attributes_from_conf_files(files)
    # Will parse all conf files and save them to CustomAttribute
    files.select { |x| x.name.include?('.conf') }.each do |file|
      save_custom_attributes(file) if file.contents
    end
  end

  def add_unique_names(file, hashes)
    hashes.each do |x|
      # Adding unique ID for all custom attributes of a host, otherwise drift filters out the non unique ones
      section = x[:section] || ""
      name    = x[:name]    || ""
      x[:unique_name] = "#{file.name}:#{section}:#{name}"
    end
    hashes
  end

  def save_custom_attributes(file)
    hashes = TelefonicaConfigurationParser.parse(file.contents)
    hashes = add_unique_names(file, hashes)
    EmsRefresh.save_custom_attributes_inventory(file, hashes, :scan) if hashes
  end

  def validate_set_node_maintenance
    {:available => true,   :message => nil}
  end

  def validate_unset_node_maintenance
    {:available => true,   :message => nil}
  end

  def disconnect_ems(e = nil)
    self.availability_zone = nil if e.nil? || ext_management_system == e
    super
  end

  def manageable_queue(userid = "system", _options = {})
    task_opts = {
      :action => "Setting node to manageable",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => "manageable",
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :msg_timeout => ::Settings.host_manageable.queue_timeout.to_i_with_method,
      :args        => []
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def manageable
    connection = ext_management_system.telefonica_handle.detect_baremetal_service
    response = connection.set_node_provision_state(name, "manage")

    if response.status == 202
      EmsRefresh.queue_refresh(ext_management_system)
    end
  rescue => e
    _log.error "host=[#{name}], error: #{e}"
    raise MiqException::MiqTelefonicaInfraHostSetManageableError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def introspect_queue(userid = "system", _options = {})
    task_opts = {
      :action => "Introspect node",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => "introspect",
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :msg_timeout => ::Settings.host_introspect.queue_timeout.to_i_with_method,
      :args        => []
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def introspect
    connection = ext_management_system.telefonica_handle.detect_workflow_service
    workflow = "tripleo.baremetal.v1.introspect"
    input = { :node_uuids => [name] }
    response = connection.create_execution(workflow, input)
    workflow_state = response.body["state"]
    workflow_execution_id = response.body["id"]

    while workflow_state == "RUNNING"
      sleep 5
      response = connection.get_execution(workflow_execution_id)
      workflow_state = response.body["state"]
    end

    if workflow_state == "SUCCESS"
      EmsRefresh.queue_refresh(ext_management_system)
    end
  rescue => e
    _log.error "host=[#{name}], error: #{e}"
    raise MiqException::MiqTelefonicaInfraHostIntrospectError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def provide_queue(userid = "system", _options = {})
    task_opts = {
      :action => "Provide Host (Setting Host to available state)",
      :userid => userid
    }
    queue_opts = {
      :class_name  => self.class.name,
      :instance_id => id,
      :method_name => "provide",
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :msg_timeout => ::Settings.host_provide.queue_timeout.to_i_with_method,
      :args        => []
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def provide
    connection = ext_management_system.telefonica_handle.detect_workflow_service
    workflow = "tripleo.baremetal.v1.provide"
    input = { :node_uuids => [name] }
    response = connection.create_execution(workflow, input)
    workflow_state = response.body["state"]
    workflow_execution_id = response.body["id"]

    while workflow_state == "RUNNING"
      sleep 5
      response = connection.get_execution(workflow_execution_id)
      workflow_state = response.body["state"]
    end
    if workflow_state == "SUCCESS"
      EmsRefresh.queue_refresh(ext_management_system)
    end
  rescue => e
    _log.error "host=[#{name}], error: #{e}"
    raise MiqException::MiqTelefonicaInfraHostProvideError, parse_error_message_from_fog_response(e), e.backtrace
  end

  def validate_start
    if state.casecmp("off") == 0
      {:available => true,   :message => nil}
    else
      {:available => false,  :message => _("Cannot start. Already on.")}
    end
  end

  def start(userid = "system")
    ironic_set_power_state_queue(userid, "power on")
  end

  def validate_stop
    if state.casecmp("on") == 0
      {:available => true,   :message => nil}
    else
      {:available => false,  :message => _("Cannot stop. Already off.")}
    end
  end

  def stop(userid = "system")
    ironic_set_power_state_queue(userid, "power off")
  end

  def validate_destroy
    if archived?
      {:available => true, :message => nil}
    elsif hardware.provision_state == "active"
      {:available => false, :message => "Cannot remove #{name} because it is in #{hardware.provision_state} state."}
    else
      {:available => true, :message => nil}
    end
  end

  def destroy_queue
    destroy_ironic_queue
  end

  def destroy_ironic_queue(userid = "system")
    task_opts = {
      :action => "Deleting Ironic node: #{uid_ems} for user #{userid}",
      :userid => userid
    }

    queue_opts = {
      :class_name  => self.class.name,
      :method_name => "destroy_ironic",
      :instance_id => id,
      :priority    => MiqQueue::HIGH_PRIORITY,
      :role        => 'ems_operations',
      :zone        => my_zone,
      :msg_timeout => ::Settings.host_delete.queue_timeout.to_i_with_method,
      :args        => []
    }
    MiqTask.generic_action_with_callback(task_opts, queue_opts)
  end

  def destroy_ironic
    # Archived node has no associated back end provider; just delete the AR object
    if archived?
      destroy
    else
      connection = ext_management_system.telefonica_handle.detect_baremetal_service
      response = connection.delete_node(name)

      if response.status == 204
        Host.destroy_queue(id)
      end
    end
  rescue => e
    _log.error "ironic node=[#{uid_ems}], error: #{e}"
    if archived?
      raise e
    else
      raise MiqException::MiqTelefonicaInfraHostDestroyError, parse_error_message_from_fog_response(e), e.backtrace
    end
  end

  def refresh_network_interfaces(ssu)
    smartstate_network_ports = MiqLinux::Utils.parse_network_interface_list(ssu.shell_exec("ip a"))

    neutron_network_ports = network_ports.where(:source => :refresh).each_with_object({}) do |network_port, obj|
      obj[network_port.mac_address] = network_port
    end
    neutron_cloud_subnets = ext_management_system.network_manager.cloud_subnets
    hashes = []

    smartstate_network_ports.each do |network_port|
      existing_network_port = neutron_network_ports[network_port[:mac_address]]
      if existing_network_port.blank?
        cloud_subnets = neutron_cloud_subnets.select do |neutron_cloud_subnet|
          if neutron_cloud_subnet.ip_version == 4
            IPAddr.new(neutron_cloud_subnet.cidr).include?(network_port[:fixed_ip])
          else
            IPAddr.new(neutron_cloud_subnet.cidr).include?(network_port[:fixed_ipv6])
          end
        end

        hashes << {:name          => network_port[:name] || network_port[:mac_address],
                   :type          => "ManageIQ::Providers::Telefonica::NetworkManager::NetworkPort",
                   :mac_address   => network_port[:mac_address],
                   :cloud_subnets => cloud_subnets,
                   :device        => self,
                   :fixed_ips     => {:subnet_id     => nil,
                                      :ip_address    => network_port[:fixed_ip],
                                      :ip_address_v6 => network_port[:fixed_ipv6]}}

      elsif existing_network_port.name.blank?
        # Just updating a names of network_ports refreshed from Neutron, rest of attributes
        # is handled in refresh section.
        existing_network_port.update_attributes(:name => network_port[:name])
      end
    end
    unless hashes.blank?
      EmsRefresh.save_network_ports_inventory(ext_management_system, hashes, nil, :scan)
    end
  rescue => e
    _log.warn("Error in refreshing network interfaces of host #{id}. Error: #{e.message}")
    _log.warn(e.backtrace.join("\n"))
  end

  def self.display_name(number = 1)
    n_('Host (Telefonica)', 'Hosts (Telefonica)', number)
  end
end

require 'etc'
require 'fileutils'
require 'ood_support'
require 'pathname'
require 'yaml/store'


class Mapping < ActiveRecord::Base
  attr_accessor :save_message
  validates :user, :app, :dataset, presence: true
  validate :dataset_path_must_exist
  validates_uniqueness_of :user, scope: [:user, :app], message: "Unable to create a second mapping between user and app."

  # Type dataset as a Pathname
  def dataset
    Pathname.new(super)
  end

  # Type app as a Pathname
  def app
    Pathname.new(super)
  end

  # @return [Array<String>]
  def self.datasets
    select(:dataset).distinct.order(:dataset).pluck(:dataset)
  end

  def self.dump_to_yaml
    mappings = []
    Mapping.find_each do |mapping|
      mapping_as_hash = mapping.to_hash
      mapping_as_hash[:app] = mapping_as_hash[:app].to_s
      mapping_as_hash[:dataset] = mapping_as_hash[:dataset].to_s

      mappings << mapping_as_hash
    end

    store = YAML::Store.new(Configuration.yaml_file_path)

    store.transaction do
      store[:mappings] = mappings
    end
  end

  # Ensure that a user can use a given mapping
  # @return [Boolean]
  def is_still_valid?
    return app.exist? && dataset.exist? && user_has_permissions_on_both?
  end

  # @return [Hash]
  def to_hash
    {:app => app, :user => user, :dataset => dataset, :extensions => extensions}
  end

  # Custom destructor
  def self.destroy_and_remove_facls(id)
    begin
      mapping = find(id)
      mapping.remove_rx_facl(mapping.dataset)
      mapping.remove_rx_facl(mapping.app)
      mapping.destroy
      dump_to_yaml
      @save_message = 'Mapping successfully destroyed.'

      return true
    rescue OodSupport::InvalidPath, OodSupport::BadExitCode => e
      @save_message = 'Unable to destroy mapping because ' + e.to_s

      return false
    rescue ActiveRecord::RecordNotFound  # User is probably mashing the delete
      return false
    end
  end

  # Create a user readable string from the error.messages hash
  def format_error_messages
    @save_message = errors.messages.map {|_, message| message}.join(' ')
  end

  # Custom save method
  def save_and_set_facls
    unless valid?
      format_error_messages
      return false
    end

    begin
      success = save(:validate => false)

      add_rx_facl(app)
      add_rx_facl(dataset)
      Mapping.dump_to_yaml
      @save_message = 'Mapping successfully created.'

      return true
    rescue OodSupport::InvalidPath, OodSupport::BadExitCode => e
      @save_message = "Unable to set FACLS because " + e.to_s
      
      return false
    end
  end

  # @return [Boolean]
  def self.has_directory_permission_errors?
    permission_sensitive_dirs.any?{|directory| ! directory_perms_are_775?(directory)}
  end

  # @return [Array<String>]
  def self.permission_sensitive_dirs
    dirs = []

    Configuration.production_database_path.ascend do |directory|
      if Etc.getpwuid(directory.stat.uid).name != 'root' and directory.directory?
        dirs << directory
      end
    end

    dirs.sort
  end

  # @return [String]
  def self.directory_permissions_command
    permission_sensitive_dirs.map{|directory| "chmod 2775 #{directory.to_s}"}.join(' && ')
  end

  # @return [Boolean]
  def should_add_facl?(pathname)
    # Calling owned first protects rx_facl_exists? from throwing InvalidPath
    can_modify_facl?(pathname) && ! rx_facl_exists?(pathname)
  end

  # Idempotently add a RX entry to the ACL for a file
  def add_rx_facl(pathname)
    return unless should_add_facl?(pathname)

    entry = build_facl_entry_for_user(user, Configuration.facl_user_domain)
    OodSupport::ACLs::Nfs4ACL.add_facl(path: pathname, entry: entry)
  end

  # Check if pathname / user combination occurs once or less in the database
  # @return [Boolean] 
  def pathname_uniq_for_user?(pathname)    
    Mapping.where(
      '(app = ? OR dataset = ?) AND user = ?',
      pathname.to_s, pathname.to_s, user
    ).count <= 1
  end

  # @return [Boolean]
  def should_remove_facl?(pathname)
    can_modify_facl?(pathname) && rx_facl_exists?(pathname) && pathname_uniq_for_user?(pathname)
  end

  # Conditionally remove RX FACLs
  #
  # Remove only if file exists, is owned, entry exists, user + (dataset, app)
  # combination is last in database
  def remove_rx_facl(pathname)
    return unless should_remove_facl?(pathname)

    entry = build_facl_entry_for_user(user, Configuration.facl_user_domain)
    OodSupport::ACLs::Nfs4ACL.rem_facl(path: pathname, entry: entry)
  end

  # Build FACL for user and domain combination
  # @return [Nfs4Entry]
  def build_facl_entry_for_user(user, domain)
    OodSupport::ACLs::Nfs4Entry.new(
      type: :A,
      flags: [],
      principle: user,
      domain: domain,
      permissions: [:r, :x]
    )
  end

  # Check if a RX ACL entry exists on pathname
  # @return [Boolean]
  def rx_facl_exists?(pathname)
    begin
      acl = OodSupport::ACLs::Nfs4ACL.get_facl(path: pathname)
      expected = build_facl_entry_for_user(user, Configuration.facl_user_domain)

      return acl.entries.include?(expected)
    rescue
      return false
    end
  end

  # Check whether a user has read/execute permissions on the app and dataset directories
  # @return [Boolean] does user have correct permissions?
  def user_has_permissions_on_both?
    ood_user = OodSupport::User.new(user)
    required_permissions = [:r, :x]

    app_facl = OodSupport::ACLs::Nfs4ACL.get_facl(path: app)
    dataset_facl = nil
    begin
      dataset_facl = OodSupport::ACLs::Nfs4ACL.get_facl(path: dataset)
    rescue OodSupport::InvalidPath, OodSupport::BadExitCode
      return false
    end

    for required_permission in required_permissions do
      return false unless app_facl.allow?(principle: ood_user, permission: required_permission)
      return false unless dataset_facl.allow?(principle: ood_user, permission: required_permission)
    end

    # Everything went well so return true
    return true
  end

  # Validator for dataset
  def dataset_path_must_exist
    errors.add(:base, "Dataset must exist.") unless dataset.exist?
  end

  # Directories between $HOME and the configured database directory must be set to 775
  # @return [Boolean]
  def self.directory_perms_are_775?(directory)
    directory.stat.mode.to_s(8).end_with?('775')
  end

  # Checks to see if FACLs are modifiable by the user
  #
  # Note that this check assumes that no negative permissions have been set.
  #
  # @return [Boolean]
  def self.can_modify_facl?(pathname)
    pathname.exist? && ( pathname.owned? || group_facl_entry_has_C_set?(pathname) )
  end

  # Get the group owner's name
  # @return [String]
  def self.get_groupname_for_pathname(pathname)
    Etc.getgrgid(pathname.stat.gid).name
  end

  # Check if pathname is owned by the admin_group
  # @return [Boolean]
  def self.app_has_correct_group_ownership?(pathname)
    get_groupname_for_pathname(pathname) == Configuration.admin_group
  end

  # Does the app have permission modification enabled for the GROUP principle
  # @return [Boolean]
  def self.group_facl_entry_has_C_set?(pathname)
    result = OodSupport::ACLs::Nfs4ACL.get_facl(
      path: pathname
    ).entries.select{
      |entry| entry.principle == 'GROUP'
    }.first.permissions.include?(:C)

    logger.debug "group_facl_entry_has_C_set?(#{pathname}) == #{result}"

    result
  end
end

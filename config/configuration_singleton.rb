require 'pathname'
require 'dotenv'

# shiny_admin app specific configuration singleton definition
#
# following the first proposal in:
#
# https://8thlight.com/blog/josh-cheek/2012/10/20/implementing-and-testing-the-singleton-pattern-in-ruby.html
#
# to avoid the traditional singleton approach or using class methods, both of
# which make it difficult to write tests against
#
# instead, ConfigurationSingleton is the definition of the configuration
# then the singleton instance used is a new class called "Configuration" which
# we set in config/boot i.e.
#
# Configuration = ConfigurationSingleton.new
#
# This is functionally equivalent to taking every instance method on
# ConfigurationSingleton and defining it as a class method on Configuration.
#
class ConfigurationSingleton

  # The app's configuration root directory
  # @return [Pathname] path to configuration root
  def config_root
    Pathname.new(ENV["OOD_APP_CONFIG_ROOT"] || "/etc/ood/config/apps/shiny_admin")
  end

  def load_external_config?
    to_bool(ENV.fetch('OOD_LOAD_EXTERNAL_CONFIG', (rails_env == 'production')))
  end

  # Load the dotenv local files first, then the /etc dotenv files and
  # the .env and .env.production or .env.development files.
  #
  # Doing this in two separate loads means OOD_APP_CONFIG_ROOT can be specified in
  # the .env.local file, which will specify where to look for the /etc dotenv
  # files. The default for OOD_APP_CONFIG_ROOT is /etc/ood/config/apps/shiny_admin and
  # both .env and .env.production will be searched for there.
  def load_dotenv_files
    # .env.local first, so it can override OOD_APP_CONFIG_ROOT
    Dotenv.load(*dotenv_local_files)

    # load the rest of the dotenv files
    Dotenv.load(*dotenv_files)
  end

  def production?
    ENV['RAILS_ENV'] == 'production'
  end

  def dataroot
    # copied from OodAppkit::Configuration#set_default_configuration
    # then modified to ensure dataroot is never nil
    #
    # FIXME: note that this would be invalid if the dataroot where
    # overridden in an initializer by modifying OodAppkit.dataroot
    # Solution: in a test, add a custom initializer that changes this, then verify it has
    # no effect or it affects both.
    #
    root = ENV['OOD_DATAROOT'] || ENV['RAILS_DATAROOT']
    if rails_env == "production"
      root ||= "~/#{ENV['OOD_PORTAL'] || 'ondemand'}/data/#{ENV['APP_TOKEN'] || 'sys/shiny_admin'}"
    else
      root ||= app_root.join("data")
    end

    Pathname.new(root).expand_path
  end

  def app_token
    if ENV['APP_TOKEN']
      ENV['APP_TOKEN']
    elsif rails_env == "production"
      "sys/#{ENV['OOD_PORTAL'] || 'ondemand'}/shiny_admin"
    else
      "#{rails_env}/shiny_admin"
    end
  end

  def shared_apps_root
    Pathname.new(ENV['SHARED_APPS_ROOT']).expand_path
  end

  def app_dataset_root
    Pathname.new(ENV['APP_DATASET_ROOT']).expand_path
  end

  def production_database_path
    # FIXME: add support/handling for DATABASE_URL
    Pathname.new(ENV["DATABASE_PATH"] || dataroot.join('production.sqlite3'))
  end

  def facl_user_domain
    ENV['FACL_USER_DOMAIN']
  end

  def users_from_group
    ENV['USERS_FROM_GROUP']
  end

  def yaml_file_path
    Pathname.new(ENV['SHARED_APPS_ROOT']).expand_path().join('mappings.yaml')
  end

  private

  # The environment
  # @return [String] "development", "test", or "production"
  def rails_env
    ENV['RAILS_ENV'] || ENV['RACK_ENV'] || "development"
  end

  # The app's root directory
  # @return [Pathname] path to app root
  def app_root
    Pathname.new(File.expand_path("../../",  __FILE__))
  end

  def dotenv_local_files
    [
      app_root.join(".env.#{rails_env}.local"),
      (app_root.join(".env.local") unless rails_env == "test"),
    ].compact
  end

  def dotenv_files
    [
      (config_root.join("env") if load_external_config?),
      app_root.join(".env.#{rails_env}"),
      app_root.join(".env")
    ].compact
  end

  FALSE_VALUES=[nil, false, '', 0, '0', 'f', 'F', 'false', 'FALSE', 'off', 'OFF', 'no', 'NO']

  # Bool coersion pulled from ActiveRecord::Type::Boolean#cast_value
  #
  # @return [Boolean] false for falsy value, true for everything else
  def to_bool(value)
    ! FALSE_VALUES.include?(value)
  end
end

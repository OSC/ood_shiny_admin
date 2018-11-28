class ManagedFile
  def file_acl_template
    <<~EOF
      A::OWNER@:rwatTnNcCoy
      A:g:GROUP@:rwatncCy
      A::EVERYONE@:rtncy
    EOF
  end


  def directory_acl_template
    <<~EOF
      A::OWNER@:rwaDxtTnNcCoy
      A:g:GROUP@:rwaDxtncCy
      A::EVERYONE@:rxtncy
    EOF
  end

  def user_access_facls(users)
    users.sort.map {|user| "A::#{user}@osc.edu:rx" }.join("\n")
  end

  def directory_user_restricted_acl_template(users)
    <<~EOF
      #{user_access_facls(users)}
      A::OWNER@:rwaDxtTnNcCoy
      A:g:GROUP@:rwaDxtncCy
      A::EVERYONE@:tncy
    EOF
  end

  def dataset_acl_template(path)
    directory_user_restricted_acl_template(Mapping.users_that_have_mappings_to_dataset(path))
  end

  def app_acl_template(path)
    directory_user_restricted_acl_template(Mapping.users_that_have_mappings_to_app(path))
  end

  def setfacl(path, acl)
    o, e, s = Open3.capture3("nfs4_setfacl -S -", :stdin_data => acl)
    s.success? ? o : raise(e)
  end

  def getfacl(path)
    o, e, s = Open3.capture3("nfs4_getfacl", path.to_s)
    s.success? ? o : raise(e)
  end

  # Do comparision, but without g
  #
  # e.g.
  # project space vs home directory
  # A::GROUP@:rxtncy vs A:g:GROUP@:rxtncy
  #
  # Can't seem to use OodSupport::Nfs4Entry for this, unfortunately.
  #
  # OodSupport::Nfs4Entry#group_owner_entry? is broken cause it assumes
  # principle is GROUP AND it will contain the g
  #
  def facls_different?(acl1, acl2)
    sanitize_acl_for_comparison(acl1) != sanitize_acl_for_comparison(acl2)
  end

  # remove g from A:g:GROUP line
  # remove o from A::OWNER@: line
  # strip whitespace
  def sanitize_acl_for_comparison(acl)
    acl.sub(/A:g:GROUP/, 'A::GROUP').strip
  end

  def managed_datasets
    @managed_datasets ||= installed_datasets(Configuration.app_dataset_root)
  end

  def dataset?(path)
    managed_datasets.include?(path.to_s)
  end

  # Set the facl on the path only if there is a difference.
  # Raise an exception if a problem occurs either getting or setting the facl.
  #
  # @return [true,nil] if FACL modified; [false, nil] if no change applied;
  #         [false, error_message] if exception occurred
  def fix_facl(path, acl)
    if facls_different?(get_facl(path), acl)
      set_facl(path, acl)
      [true, nil]
    else
      [false, nil]
    end
  rescue => e
    [false, "#{e.class}: #{e.message}"]
  end

  def acl_for_path_under_dataset_root(path)
    if dataset?(path)
      app_acl_template(path)
    elsif path.directory?
      directory_acl_template
    else
      file_acl_template
    end
  end

  def fix_dataset_root_permissions
    log = { updated: [], failed: [] }

    Configuration.app_dataset_root.glob("**/*").each do |path|
      updated, error = fix_facl(path, acl_for_path_under_dataset_root(path))
      log[:updated] << path if updated
      log[:failed] << { path: path, error: error } if error
    end

    log
  end

  def fix_app_permissions
    log = { updated: [], failed: [] }

    Mapping.installed_apps.each do |path|
      updated, error = fix_facl(path, app_acl_template(path))
      log[:updated] << path if updated
      log[:failed] << { path: path, error: error } if error
    end

    log
  end
end

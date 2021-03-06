require 'fileutils'
require 'pathname'

require 'modulesync/cli'
require 'modulesync/constants'
require 'modulesync/hook'
require 'modulesync/puppet_module'
require 'modulesync/renderer'
require 'modulesync/settings'
require 'modulesync/util'

require 'monkey_patches'

module ModuleSync # rubocop:disable Metrics/ModuleLength
  class Error < StandardError; end

  include Constants

  def self.config_defaults
    {
      :project_root         => 'modules/',
      :managed_modules_conf => 'managed_modules.yml',
      :configs              => '.',
      :tag_pattern          => '%s'
    }
  end

  def self.options
    @options
  end

  def self.local_file(config_path, file)
    File.join(config_path, MODULE_FILES_DIR, file)
  end

  # List all template files.
  #
  # Only select *.erb files, and strip the extension. This way all the code will only have to handle bare paths,
  # except when reading the actual ERB text
  def self.find_template_files(local_template_dir)
    if File.exist?(local_template_dir)
      Find.find(local_template_dir).find_all { |p| p =~ /.erb$/ && !File.directory?(p) }
          .collect { |p| p.chomp('.erb') }
          .to_a
    else
      $stderr.puts "#{local_template_dir} does not exist." \
        ' Check that you are working in your module configs directory or' \
        ' that you have passed in the correct directory with -c.'
      exit 1
    end
  end

  def self.relative_names(file_list, path)
    file_list.map { |file| file.sub(/#{path}/, '') }
  end

  def self.managed_modules
    config_file = config_path(options[:managed_modules_conf], options)
    filter = options[:filter]
    negative_filter = options[:negative_filter]

    managed_modules = Util.parse_config(config_file)
    if managed_modules.empty?
      $stderr.puts "No modules found in #{config_file}." \
        ' Check that you specified the right :configs directory and :managed_modules_conf file.'
      exit 1
    end
    managed_modules.select! { |m| m =~ Regexp.new(filter) } unless filter.nil?
    managed_modules.reject! { |m| m =~ Regexp.new(negative_filter) } unless negative_filter.nil?
    managed_modules.map { |given_name, options| PuppetModule.new(given_name, options) }
  end

  def self.hook(options)
    hook = Hook.new(HOOK_FILE, options)

    case options[:hook]
    when 'activate'
      hook.activate
    when 'deactivate'
      hook.deactivate
    end
  end

  def self.manage_file(puppet_module, filename, settings, options)
    namespace = settings.additional_settings[:namespace]
    module_name = settings.additional_settings[:puppet_module]
    configs = settings.build_file_configs(filename)
    target_file = puppet_module.path(filename)
    if configs['delete']
      Renderer.remove(target_file)
    else
      templatename = local_file(options[:configs], filename)
      begin
        erb = Renderer.build(templatename)
        # Meta data passed to the template as @metadata[:name]
        metadata = {
          :module_name => module_name,
          :workdir     => puppet_module.working_directory,
          :target_file => target_file,
        }
        template = Renderer.render(erb, configs, metadata)
        Renderer.sync(template, target_file)
      rescue StandardError => e
        $stderr.puts "#{puppet_module.given_name}: Error while rendering file: '#{filename}'"
        raise
      end
    end
  end

  def self.manage_module(puppet_module, module_files, defaults)
    puts "Syncing '#{puppet_module.given_name}'"
    puppet_module.repository.prepare_workspace(options[:branch]) unless options[:offline]

    module_configs = Util.parse_config puppet_module.path(MODULE_CONF_FILE)
    settings = Settings.new(defaults[GLOBAL_DEFAULTS_KEY] || {},
                            defaults,
                            module_configs[GLOBAL_DEFAULTS_KEY] || {},
                            module_configs,
                            :puppet_module => puppet_module.repository_name,
                            :git_base => options[:git_base],
                            :namespace => puppet_module.repository_namespace)

    settings.unmanaged_files(module_files).each do |filename|
      $stdout.puts "Not managing '#{filename}' in '#{puppet_module.given_name}'"
    end

    files_to_manage = settings.managed_files(module_files)
    files_to_manage.each { |filename| manage_file(puppet_module, filename, settings, options) }

    if options[:noop]
      puts "Using no-op. Files in '#{puppet_module.given_name}' may be changed but will not be committed."
      puppet_module.repository.show_changes(options)
      options[:pr] && \
        pr(puppet_module).manage(puppet_module.repository_namespace, puppet_module.repository_name, options)
    elsif !options[:offline]
      pushed = puppet_module.repository.submit_changes(files_to_manage, options)
      # Only bump/tag if pushing didn't fail (i.e. there were changes)
      if pushed && options[:bump]
        new = puppet_module.bump(options[:message], options[:changelog])
        puppet_module.repository.tag(new, options[:tag_pattern]) if options[:tag]
      end
      pushed && options[:pr] && \
        pr(puppet_module).manage(puppet_module.repository_namespace, puppet_module.repository_name, options)
    end
  end

  def self.config_path(file, options)
    return file if Pathname.new(file).absolute?
    File.join(options[:configs], file)
  end

  def config_path(file, options)
    self.class.config_path(file, options)
  end

  def self.update(cli_options)
    @options = config_defaults.merge(cli_options)
    defaults = Util.parse_config(config_path(CONF_FILE, options))

    if options[:pr]
      unless options[:branch]
        $stderr.puts 'A branch must be specified with --branch to use --pr!'
        raise
      end

      @pr = create_pr_manager if options[:pr]
    end

    local_template_dir = config_path(MODULE_FILES_DIR, options)
    local_files = find_template_files(local_template_dir)
    module_files = relative_names(local_files, local_template_dir)

    errors = false
    # managed_modules is either an array or a hash
    managed_modules.each do |puppet_module|
      begin
        manage_module(puppet_module, module_files, defaults)
      rescue ModuleSync::Error, Git::GitExecuteError => e
        message = e.message || "Error during '#{options[:command]}'"
        $stderr.puts "#{puppet_module.given_name}: #{message}"
        exit 1 unless options[:skip_broken]
        errors = true
        $stdout.puts "Skipping '#{puppet_module.given_name}' as update process failed"
      rescue StandardError => e
        raise unless options[:skip_broken]
        errors = true
        $stdout.puts "Skipping '#{puppet_module.given_name}' as update process failed"
      end
    end
    exit 1 if errors && options[:fail_on_warnings]
  end

  def self.pr(puppet_module)
    module_options = puppet_module.options
    github_conf = module_options[:github]
    gitlab_conf = module_options[:gitlab]

    if !github_conf.nil?
      base_url = github_conf[:base_url] || ENV.fetch('GITHUB_BASE_URL', 'https://api.github.com')
      require 'modulesync/pr/github'
      ModuleSync::PR::GitHub.new(github_conf[:token], base_url)
    elsif !gitlab_conf.nil?
      base_url = gitlab_conf[:base_url] || ENV.fetch('GITLAB_BASE_URL', 'https://gitlab.com/api/v4')
      require 'modulesync/pr/gitlab'
      ModuleSync::PR::GitLab.new(gitlab_conf[:token], base_url)
    elsif @pr.nil?
      $stderr.puts 'No GitHub or GitLab token specified for --pr!'
      raise
    else
      @pr
    end
  end

  def self.create_pr_manager
    github_token = ENV.fetch('GITHUB_TOKEN', '')
    gitlab_token = ENV.fetch('GITLAB_TOKEN', '')

    if !github_token.empty?
      require 'modulesync/pr/github'
      ModuleSync::PR::GitHub.new(github_token, ENV.fetch('GITHUB_BASE_URL', 'https://api.github.com'))
    elsif !gitlab_token.empty?
      require 'modulesync/pr/gitlab'
      ModuleSync::PR::GitLab.new(gitlab_token, ENV.fetch('GITLAB_BASE_URL', 'https://gitlab.com/api/v4'))
    else
      warn '--pr specified without environment variables GITHUB_TOKEN or GITLAB_TOKEN'
    end
  end
end

require 'git'

module ModuleSync
  # Wrapper for Git in ModuleSync context
  class Repository
    def initialize(directory:, remote:)
      @directory = directory
      @remote = remote
    end

    def git
      @git ||= Git.open @directory
    end

    # This is an alias to minimize code alteration
    def repo
      git
    end

    def remote_branch_exists?(branch)
      repo.branches.remote.collect(&:name).include?(branch)
    end

    def local_branch_exists?(branch)
      repo.branches.local.collect(&:name).include?(branch)
    end

    def remote_branch_differ?(local_branch, remote_branch)
      !remote_branch_exists?(remote_branch) ||
        repo.diff("#{local_branch}..origin/#{remote_branch}").any?
    end

    def default_branch
      symbolic_ref = repo.branches.find { |b| b.full =~ %r{remotes/origin/HEAD} }
      return unless symbolic_ref
      %r{remotes/origin/HEAD\s+->\s+origin/(?<branch>.+?)$}.match(symbolic_ref.full)[:branch]
    end

    def switch_branch(branch)
      unless branch
        branch = default_branch
        puts "Using repository's default branch: #{branch}"
      end
      return if repo.current_branch == branch

      if local_branch_exists?(branch)
        puts "Switching to branch #{branch}"
        repo.checkout(branch)
      elsif remote_branch_exists?(branch)
        puts "Creating local branch #{branch} from origin/#{branch}"
        repo.checkout("origin/#{branch}")
        repo.branch(branch).checkout
      else
        repo.checkout('origin/master')
        puts "Creating new branch #{branch}"
        repo.branch(branch).checkout
      end
    end

    def prepare_workspace(branch)
      # Repo needs to be cloned in the cwd
      if !Dir.exist?("#{@directory}/.git")
        puts 'Cloning repository fresh'
        puts "Cloning from '#{@remote}'"
        @git = Git.clone(@remote, @directory)
        switch_branch(branch)
      # Repo already cloned, check out master and override local changes
      else
        # Some versions of git can't properly handle managing a repo from outside the repo directory
        Dir.chdir(@directory) do
          puts "Overriding any local changes to repository in '#{@directory}'"
          @git = Git.open('.')
          repo.fetch 'origin', prune: true
          repo.reset_hard
          switch_branch(branch)
          git.pull('origin', branch) if remote_branch_exists?(branch)
        end
      end
    end

    def tag(version, tag_pattern)
      tag = tag_pattern % version
      puts "Tagging with #{tag}"
      repo.add_tag(tag)
      repo.push('origin', tag)
    end

    def checkout_branch(branch)
      selected_branch = branch || repo.current_branch || 'master'
      repo.branch(selected_branch).checkout
      selected_branch
    end

    # Git add/rm, git commit, git push
    def submit_changes(files, options)
      message = options[:message]
      branch = checkout_branch(options[:branch])
      files.each do |file|
        if repo.status.deleted.include?(file)
          repo.remove(file)
        elsif File.exist?("#{@directory}/#{file}")
          repo.add(file)
        end
      end
      begin
        opts_commit = {}
        opts_push = {}
        opts_commit = { :amend => true } if options[:amend]
        opts_push = { :force => true } if options[:force]
        if options[:pre_commit_script]
          script = "#{File.dirname(File.dirname(__FILE__))}/../contrib/#{options[:pre_commit_script]}"
          `#{script} #{@directory}`
        end
        repo.commit(message, opts_commit)
        if options[:remote_branch]
          if remote_branch_differ?(branch, options[:remote_branch])
            repo.push('origin', "#{branch}:#{options[:remote_branch]}", opts_push)
            puts "Changes have been pushed to: '#{branch}:#{options[:remote_branch]}'"
          end
        else
          repo.push('origin', branch, opts_push)
          puts "Changes have been pushed to: '#{branch}'"
        end
      rescue Git::GitExecuteError => e
        raise unless e.message.match?(/working (directory|tree) clean/)

        puts "There were no changes in '#{@directory}'. Not committing."
        return false
      end

      true
    end

    # Needed because of a bug in the git gem that lists ignored files as
    # untracked under some circumstances
    # https://github.com/schacon/ruby-git/issues/130
    def untracked_unignored_files
      ignore_path = "#{@directory}/.gitignore"
      ignored = File.exist?(ignore_path) ? File.read(ignore_path).split : []
      repo.status.untracked.keep_if { |f, _| ignored.none? { |i| File.fnmatch(i, f) } }
    end

    def show_changes(options)
      checkout_branch(options[:branch])

      puts 'Files changed:'
      repo.diff('HEAD', '--').each do |diff|
        puts diff.patch
      end

      puts 'Files added:'
      untracked_unignored_files.each_key do |file|
        puts file
      end

      puts "\n\n"
      puts '--------------------------------'

      git.diff('HEAD', '--').any? || untracked_unignored_files.any?
    end
  end
end

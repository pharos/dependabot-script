# frozen_string_literal: true

require "dependabot/omnibus"
require "dependabot/hex/version"
require_relative "dependabot-config"
require_relative "message_builder"

# MonkeyPatch: dependabot to avoid issues relating to https://github.com/dependabot/dependabot-core/pull/1472
Dependabot::Nuget::UpdateChecker::RepositoryFinder.class_eval do
  def build_v2_url(response, repo_details)
    doc = Nokogiri::XML(response.body)
    doc.remove_namespaces!
    base_url = doc.at_xpath("service")&.attributes&.fetch("base", nil)&.value

    base_url ||= repo_details.fetch(:url)
    return unless base_url

    {
      repository_url: base_url,
      versions_url: File.join(
        base_url,
        "FindPackagesById()?id='#{dependency.name}'"
      ),
      auth_header: auth_header_for_token(repo_details.fetch(:token)),
      repository_type: "v2"
    }
  end
end

Dependabot::Source.class_eval do
  PHAROS_SOURCE = %r{
      (?<provider>git-us.pharos)
      (?:\.com)[/:]
      (?<repo>[\w.-]+/(?:(?!\.git|\.\s)[\w.-])+)
      (?:(?:/tree|/blob)/(?<branch>[^/]+)/(?<directory>.*)[\#|/])?
    }x.freeze

  CUSTOM_SOURCE_REGEX = /
      (?:#{Dependabot::Source::SOURCE_REGEX})|
      (?:#{PHAROS_SOURCE})
    /x.freeze

  def self.from_url(url_string)
    return unless url_string&.match?(CUSTOM_SOURCE_REGEX)

    captures = url_string.match(CUSTOM_SOURCE_REGEX).named_captures

    if captures.fetch("provider") == "git-us.pharos"
      return new(
        provider: "gitlab",
        repo: captures.fetch("repo"),
        directory: captures.fetch("directory"),
        branch: captures.fetch("branch"),
        hostname: "git-us.pharos.com",
        api_endpoint: "https://git-us.pharos.com/api/v4"
      )
    end

    new(
      provider: captures.fetch("provider"),
      repo: captures.fetch("repo"),
      directory: captures.fetch("directory"),
      branch: captures.fetch("branch")
    )
  end
end

Dependabot::PullRequestCreator::PrNamePrefixer.class_eval do
  def capitalize_first_word?
    if commit_message_options.key?(:prefix)
      return true if Dependabot::PullRequestCreator::PrNamePrefixer::ANGULAR_PREFIXES.include?(commit_message_options[:prefix])

      return !commit_message_options[:prefix]&.strip&.match?(/\A[a-z]/)
    end

    return capitalise_first_word_from_last_dependabot_commit_style if last_dependabot_commit_style

    capitalise_first_word_from_previous_commits
  end
end

Dependabot::MetadataFinders::Base::CommitsFinder.class_eval do
  def gitlab_client
    @gitlab_client ||= if source.hostname == "git-us.pharos.com"
                         Dependabot::Clients::GitlabWithRetries.for_source(source: source, credentials: credentials)
                       else
                         Dependabot::Clients::GitlabWithRetries.for_gitlab_dot_com(credentials: credentials)
                       end
  end
end

# noinspection RubyResolve
class GitLabProcessor
  def initialize(organisation, available_credentials)
    @organisation = organisation
    @available_credentials = available_credentials

    @organisation_credentials = available_credentials.
                                select { |cred| cred["type"] == "git_source" }.
                                find { |cred| cred["host"] == "git-us.pharos.com" }

    @gitlab_client = Gitlab.client(
      endpoint: "https://#{@organisation_credentials&.fetch('host')}/api/v4",
      private_token: @organisation_credentials&.fetch("password")
    )

    @merge_request_author = "dependabot"
  end

  def process(repository_name, mr_limit_per_repo)
    puts "#{@organisation} => #{repository_name} => Checking for repository...."
    project = @gitlab_client.project(repository_name)
    process_project(project, mr_limit_per_repo)
  rescue Gitlab::Error::NotFound
    puts "#{@organisation} => #{repository_name} => Named repository not found."
  rescue Gitlab::Error::Forbidden
    puts "#{@organisation} => #{repository_name} => Access not granted to repository"
  end

  def process_project(project, mr_limit_per_repo)
    puts "#{@organisation} => #{project.path_with_namespace} => Checking for Depenadbot configuration file..."
    response_file = @gitlab_client.get_file(project.id, ".dependabot/config.yml", "master")
    response_config = Base64.decode64(response_file.content)
    config = YAML.safe_load(response_config)
    config["update_configs"].each do |update_config|
      process_dependabot_config(project, DependabotConfig.new(update_config), mr_limit_per_repo)
    end
  rescue Gitlab::Error::NotFound => e
    generate_bug_dependabot_config(project, e)
  rescue Gitlab::Error::Forbidden => e
    generate_bug_dependabot_config(project, e)
  end

  def generate_bug_dependabot_config(project, error)
    puts "#{@organisation} => #{project.path_with_namespace} => Dependabot configuration file issue, raising bug if required..."
    puts error.message
  end

  def process_dependabot_config(project, dependabot_config, mr_limit_per_repo)
    # not supported: target_branch, default_reviewers, default_assignees, default_labels, allowed_updates, version_requirement_updates
    # not supported: ignored_updates.version_requirement
    # not supported: automerged_updates.dependency_type, limited support for automerged_updates.update_type

    package_manager = package_manager(dependabot_config)

    update_schedule = case dependabot_config.update_schedule
                      when "live" then true
                      when "daily" then true
                      when "weekly" then Date.today.strftime("%w").to_i == 1
                      when "monthly" then Date.today.strftime("%e").to_i == 1
                      else raise "Unsupported update schedule: #{dependabot_config.update_schedule}"
                      end
    if update_schedule == false
      puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => Skipping dependency checking"
      return
    end

    open_merge_requests = @gitlab_client.merge_requests(project.id, { state: "opened" })
    if open_merge_requests.count { |merge_request| merge_request.author.username == @merge_request_author } == mr_limit_per_repo
      puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => Skipping; maximum number of allowed opened MR requests has been reached"
      return
    end

    puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => Dependabot configuration { directory: #{dependabot_config.directory} }"
    source = Dependabot::Source.new(
      provider: "gitlab",
      hostname: @organisation_credentials&.fetch("host"),
      api_endpoint: @gitlab_client.endpoint,
      repo: project.path_with_namespace,
      directory: dependabot_config.directory,
      branch: nil
    )

    puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => Fetching dependency files..."
    fetcher = Dependabot::FileFetchers.for_package_manager(package_manager).new(
      source: source,
      credentials: @available_credentials
    )
    files = fetcher.files
    commit = fetcher.commit

    puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => Parsing dependencies information.."
    parser = Dependabot::FileParsers.for_package_manager(package_manager).new(
      dependency_files: files,
      source: source,
      credentials: @available_credentials
    )

    dependency_groups = create_dependency_groups(package_manager, project, dependabot_config.group_updates, parser.parse, files)
    dependency_groups.each do |dependency_group|
      get_updates_for_dependency_group(package_manager, project, dependabot_config, dependency_group, files)
      open_merge_request = close_open_dependency_merge_requests(package_manager, project, dependency_group)

      next unless open_merge_request

      updated_dependencies = dependency_group.
                             dependencies.map(&:updates).
                             reject(&:empty?).
                             flatten
      next if updated_dependencies.empty?

      updater = Dependabot::FileUpdaters.for_package_manager(package_manager).new(
        dependencies: updated_dependencies,
        dependency_files: files,
        credentials: @available_credentials
      )
      pr_creator = Dependabot::PullRequestCreator.new(
        source: source,
        base_commit: commit,
        dependencies: updated_dependencies,
        files: updater.updated_dependency_files,
        credentials: @available_credentials,
        commit_message_options: dependabot_config.commit_message,
        label_language: true
      )

      # If the dependency group matches more than one package treat as a group
      if dependency_group.dependencies.length > 1
        pr_creator.send(:branch_namer).instance_variable_set(:@name, dependency_group.branch_name)
      end

      message_builder = MessageBuilder.new(
        dependency_group_name: dependency_group.group_name,
        source: pr_creator.source,
        dependencies: pr_creator.dependencies,
        files: pr_creator.files,
        credentials: pr_creator.credentials,
        commit_message_options: pr_creator.commit_message_options,
        pr_message_header: pr_creator.pr_message_header,
        pr_message_footer: pr_creator.pr_message_footer,
        vulnerabilities_fixed: pr_creator.vulnerabilities_fixed,
        github_redirection_service: pr_creator.github_redirection_service
      )
      pr_creator.instance_variable_set(:@message_builder, message_builder)
      pull_request = pr_creator.create

      unless pull_request
        puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => #{dependency_group.branch_name}) => Merge request already exists"
        next
      end
      puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => #{dependency_group.branch_name}) => Merge request created (#{pull_request.iid})"

      auto_merge = dependency_group.dependencies.
                   collect(&:auto_merge).
                   any? { |auto_merge| auto_merge }
      next unless auto_merge

      # Wait for pipelines to be created - or give up
      puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => #{dependency_group.branch_name} => Waiting for pipelines to start"
      pipelines = wait_for_pipelines_to_start(project, pull_request)
      next if pipelines.nil? || pipelines.empty?

      puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => #{dependency_group.branch_name} => Setting Merge request to auto-merge"
      @gitlab_client.accept_merge_request(
        project.id,
        pull_request.iid,
        merge_when_pipeline_succeeds: true,
        should_remove_source_branch: true
      )
    end
  rescue StandardError => e
    puts "#{@organisation} => #{project.path_with_namespace} => Failed processing: #{e.message}"
  end

  def create_dependency_groups(package_manager, project, group_updates, dependencies, files)
    groups = dependencies.select(&:top_level?).group_by do |dependency|
      group_updates?(dependency, group_updates)
    end
    branch_namer = Dependabot::PullRequestCreator::BranchNamer.new(dependencies: dependencies, files: files, target_branch: nil)
    groups.map do |group|
      group_name = group[0] == "*" ? "" : group[0] + " "
      branch_namer.instance_variable_set(:@name, (group[0] == "*" ? "dependencies" : group[0]).gsub(" ", "-"))
      source_branch = branch_namer.new_branch_name
      obj = {
        group_name: group_name,
        merge_request: merge_request_for_source_branch?(project, source_branch),
        source_branch: source_branch,
        branch_name: branch_namer.send(:sanitize_ref,
                                       (group[0] == "*" ? "dependencies" : group[0]).gsub(" ", "-")),
        dependencies: group[1].
            sort_by { |dependency| dependency.name }.
            map { |dependency| OpenStruct.new({ package: dependency, updates: [], auto_merge: false }) }
      }
      OpenStruct.new(obj)
    end
  end

  def get_updates_for_dependency_group(package_manager, project, dependabot_config, dependency_group, files)
    dependency_group.dependencies.each do |dependency|
      if ignored_updates?(dependency.package, dependabot_config.ignored_updates)
        puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => #{dependency.package.name} (#{dependency.package.version}) => Dependency ignored"
        next
      end

      puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => #{dependency.package.name} (#{dependency.package.version}) => Checking for updates.."
      checker = Dependabot::UpdateCheckers.for_package_manager(package_manager).new(
        dependency: dependency.package,
        dependency_files: files,
        credentials: @available_credentials
      )

      # Check if the dependency is up to date.
      if checker.up_to_date?
        puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => #{dependency.package.name} (#{dependency.package.version}) => Already up to date"
        next
      end

      # Check if the dependency can be updated.
      requirements_to_unlock =
        if !checker.requirements_unlocked_or_can_be?
          if checker.can_update?(requirements_to_unlock: :none) then :none
          else :update_not_possible
          end
        elsif checker.can_update?(requirements_to_unlock: :own) then :own
        elsif checker.can_update?(requirements_to_unlock: :all) then :all
        else :update_not_possible
        end
      if requirements_to_unlock == :update_not_possible
        puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => #{dependency.package.name} (#{dependency.package.version}) => Cannot be updated"
        next
      end
      dependency.updates = checker.updated_dependencies(requirements_to_unlock: requirements_to_unlock)
      dependency.auto_merge = true if auto_merge_update(dependency.package, dependabot_config.automerged_updates)
    end
  end

  def wait_for_pipelines_to_start(project, pull_request)
    max_retries = 3
    retry_count = 0
    begin
      pipelines = @gitlab_client.merge_request_pipelines(project.id, pull_request.iid).auto_paginate
      raise "Failed to merge request pipelines" if pipelines.nil? || pipelines.empty?

      pipelines
    rescue StandardError
      return nil if retry_count >= max_retries

      retry_count += 1
      puts "#{@organisation} => #{project.path_with_namespace} => Oh no, failed to get pipelines. Retries left: #{max_retries - retry_count}"
      sleep(5)
      retry
    end
  end

  def wait_while_pipelines_not_finish(project, pipelines)
    pipelines.each do |pipeline|
      obj = @gitlab_client.pipeline(project.id, pipeline.id)
      next if %w(success failed canceled skipped).include?(obj.status)

      puts "#{@organisation} => #{project.path_with_namespace} => Pipeline #{obj.id} not yet complete #{obj.status}"
      sleep(30)
      redo
    end
  end

  def ignored_updates?(dependency, ignored_updates)
    ignored_updates.each do |ignored_update|
      return true if match_dependency?(dependency.name, [ignored_update.dependency_name])
    end
    false
  end

  def auto_merge_update(dependency, automerged_updates)
    automerged_updates.each do |automerged_update|
      return true if automerged_update.update_type == "all"
      return true if match_dependency?(dependency.name, [automerged_update.dependency_name])
    end
    false
  end

  def group_updates?(dependency, group_updates)
    group_updates.each do |group_update|
      return group_update.dependency_name.capitalize if match_dependency?(dependency.name, [group_update.dependency_name])
    end
    dependency.name
  end

  def close_open_dependency_merge_requests(package_manager, project, dependency_group)
    open_merge_requests = @gitlab_client.
                          merge_requests(project.id, { state: "opened" }).
                          select { |merge_request| merge_request.author.username == @merge_request_author }

    # Dependencies that should be updated
    dependencies_updated = dependency_group.
                           dependencies.select { |dependency| dependency.updates.length >= 1 }
    close_merge_requests = []
    open_merge_request = false
    if !dependency_group.merge_request.nil?
      unrelated_updates = dependencies_updated.empty?
      dependencies_updated.each do |dependency|
        # Close merge requests with matching package name; will be part of group
        close_merge_requests += open_merge_requests.select { |merge_request| merge_request.title.include?(dependency.package.name) }

        if unrelated_to_merge_request?(dependency_group.merge_request, dependency.package, dependency.updates)
          unrelated_updates = true
        end
      end

      # Close dependency group MR is we have unrelated package updates
      close_open_merge_request(package_manager, project, dependency_group.merge_request) if unrelated_updates
      open_merge_request = unrelated_updates
    elsif dependencies_updated.length > 1
      # Close merge requests with matching package name; will be part of group
      dependencies_updated.each do |dependency|
        close_merge_requests += open_merge_requests.select { |merge_request| merge_request.title.include?(dependency.package.name) }
      end
      open_merge_request = true
    elsif dependencies_updated.length == 1
      # Close merge requests with matching package name+version provided the new version is changing
      close_merge_requests += open_merge_requests.select do |merge_request|
        merge_request.title.include?(dependencies_updated[0].package.name) &&
          merge_request.title.include?(dependencies_updated[0].package.version) &&
          !merge_request.title.include?(dependencies_updated[0].updates.first.version)
      end
      open_merge_request = !close_merge_requests.empty?
    end

    # Find open merge requests for dependencies NOT updated
    dependency_group.dependencies.
      select { |dependency| dependency.updates.empty? }.
      each do |dependency|
      close_merge_requests += open_merge_requests.
                              select { |merge_request| merge_request.title.include?(dependency.package.name) }
    end

    # Close merge requests selected
    close_merge_requests.each { |merge_request| close_open_merge_request(package_manager, project, merge_request) }
    open_merge_request
  end

  def close_open_merge_request(package_manager, project, merge_request)
    return if merge_request.nil?

    puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => Close merge request (#{merge_request.title})"
    @gitlab_client.update_merge_request(project.path_with_namespace, merge_request.iid, { state_event: "close" })

    puts "#{@organisation} => #{project.path_with_namespace} => #{package_manager} => Delete branch #{merge_request.source_branch})"
    @gitlab_client.delete_branch(project.path_with_namespace, merge_request.source_branch)
  end

  def merge_request_for_source_branch?(project, source_branch)
    open_merge_requests = @gitlab_client.merge_requests(project.id, { state: "opened" })
    merge_requests = open_merge_requests.select do |merge_request|
      merge_request.author.username == @merge_request_author &&
        merge_request.source_branch == source_branch
    end
    return nil if merge_requests.empty?

    merge_requests = merge_requests.collect do |merge_request|
      hash = merge_request.to_h
      hash["related_dependencies_updated"] = dependencies_from_merge_request?(merge_request)
      return Gitlab::ObjectifiedHash.new(hash)
    end
    merge_requests.first
  end

  def unrelated_to_merge_request?(merge_request, dependency, updated_dependencies)
    return false if merge_request.nil?

    related_dependencies = merge_request.related_dependencies_updated
    related_dependencies = related_dependencies.select { |related_dependency| related_dependency.include?(dependency.name) }
    return true if related_dependencies.empty? # package not referenced

    related_dependencies = related_dependencies.select do |related_dependency|
      related_dependency.include?(dependency.version) &&
        related_dependency.include?(updated_dependencies.first.version)
    end

    related_dependencies.empty? # package version and new version not referenced
  end

  def dependencies_from_merge_request?(merge_request)
    return [] if merge_request.nil?

    merge_request.
      description.
      each_line(chomp: true).
      select { |line| /^bumps .* from .* to .*\./i =~ line }
  end

  def match_dependency?(dependency_name, dependency_name_matches)
    match = dependency_name_matches.include? dependency_name
    if match == false
      match = dependency_name_matches.
              select { |dependency_name_match| dependency_name_match.end_with? "*" }.
              map { |dependency_name_match| dependency_name_match[0...-1] }.
              map { |dependency_name_match| dependency_name.start_with? dependency_name_match }.
              any?
    end
    match
  end

  def package_manager(dependabot_config)
    case dependabot_config.package_manager
    when "javascript"
      "npm_and_yarn"
    when "ruby:bundler"
      "bundler"
    when "php:composer"
      "composer"
    when "python"
      "pip"
    when "go:modules"
      "go_modules"
    when "go:dep"
      "dep"
    when "java:maven"
      "maven"
    when "java:gradle"
      "gradle"
    when "dotnet:nuget"
      "nuget"
    when "rust:cargo"
      "cargo"
    when "elixir:hex"
      "hex"
    when "docker"
      "docker"
    when "terraform"
      "terraform"
    when "submodules"
      "submodules"
    when "elm"
      "elm"
    when "cake"
      "cake"
    else
      raise "Unsupported package manager: #{dependabot_config.package_manager}"
    end
  end
end

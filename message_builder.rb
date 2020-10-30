require "pathname"
require "dependabot/clients/github_with_retries"
require "dependabot/clients/gitlab_with_retries"
require "dependabot/metadata_finders"
require "dependabot/pull_request_creator"

class MessageBuilder < Dependabot::PullRequestCreator::MessageBuilder
  def initialize(dependency_group_name:, source:, dependencies:, files:, credentials:,
                 pr_message_header: nil, pr_message_footer: nil,
                 commit_message_options: {}, vulnerabilities_fixed: {},
                 github_redirection_service: nil)
    super(source: source, dependencies: dependencies, files: files, credentials: credentials,
          pr_message_header: pr_message_header, pr_message_footer: pr_message_footer,
          commit_message_options: commit_message_options, vulnerabilities_fixed: vulnerabilities_fixed,
          github_redirection_service: github_redirection_service)
    @dependency_group_name = dependency_group_name
  end

  private

  def application_pr_name
    if dependencies.count == 1
      super
    elsif updating_a_property?
      super
    elsif updating_a_dependency_set?
      super
    else
      pr_name = "bump "
      pr_name = pr_name.capitalize if pr_name_prefixer.capitalize_first_word?
      pr_name += "#{@dependency_group_name}dependencies"
    end
  end

  def requirement_commit_message_intro
    msg = "Bumps the requirements on "

    msg +=
      if dependencies.count == 1
        "#{dependency_links.first} "
      else
        "#{dependency_links[0..-2].join(', ')} and #{dependency_links[-1]} "
      end

    msg + "to permit the latest version."
  end

  def multidependency_intro
    ""
  end

  def metadata_links
    if dependencies.count == 1
      return metadata_links_for_dep(dependencies.first)
    end

    dependencies.map do |dep|
      "Bumps `#{dep.display_name}` from #{previous_version(dep)} to "\
          "#{new_version(dep)}."\
          "#{metadata_links_for_dep(dep)}"
    end.join("\n\n")
  end

  def metadata_cascades
    if dependencies.one?
      return metadata_cascades_for_dep(dependencies.first)
    end

    dependencies.map do |dependency|
      msg = "Bumps #{dependency_link(dependency)} "\
              "from #{previous_version(dependency)} "\
              "to #{new_version(dependency)}."

      if vulnerabilities_fixed[dependency.name]&.one?
        msg += " **This update includes a security fix.**"
      elsif vulnerabilities_fixed[dependency.name]&.any?
        msg += " **This update includes security fixes.**"
      end

      msg + metadata_cascades_for_dep(dependency)
    end.join("\n\n")
  end

  def dependency_link(dependency)
    if source_url(dependency)
      "[#{dependency.display_name}](#{source_url(dependency)})"
    elsif homepage_url(dependency)
      "[#{dependency.display_name}](#{homepage_url(dependency)})"
    else
      dependency.display_name
    end
  end

end
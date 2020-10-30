# frozen_string_literal: true
# This script is designed to loop through all dependencies in a GHE, GitLab or
# Azure DevOps project, creating PRs where necessary.

require_relative "gitlab-processor"

# Capture environment variables.
organisation = ENV["GITLAB_ORGANIZATION"] || "Pharos"
credentials = [
  {
      "type" => "git_source",
      "host" => "github.com",
      "username" => "x-access-token",
      "password" => ENV["GITHUB_ACCESS_TOKEN"] # A GitHub access token with read access to public repos
  },
  {
    "type" => "git_source",
    "host" => ENV["GITLAB_HOSTNAME"] || "git-us.pharos.com",
    "username" => "x-access-token",
    "password" => ENV["GITLAB_ACCESS_TOKEN"]
  }
]

unless ENV["LOCAL_CONFIG_VARIABLES"].to_s.strip.empty?
  # For example:
  # "[{\"type\":\"npm_registry\",\"registry\":\
  #     "registry.npmjs.org\",\"token\":\"123\"}]"
  credentials.concat(JSON.parse(ENV["LOCAL_CONFIG_VARIABLES"]))
end

# Full name of the repo you want to create pull requests for.
repository_name = ENV["PROJECT_PATH"] # namespace/project
mr_limit_per_repo = ENV["MR_LIMIT_PER_REPO"].to_i || 5 # namespace/project

GitLabProcessor.new(organisation, credentials).process(repository_name, mr_limit_per_repo)

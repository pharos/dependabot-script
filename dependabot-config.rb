# frozen_string_literal: true

class DependabotConfig
  def initialize(config)
    @package_manager = config["package_manager"]
    @directory = config["directory"]
    @update_schedule = config["update_schedule"]
    @target_branch = config["target_branch"]

    @ignored_updates = []
    unless config["ignored_updates"].nil?
      @ignored_updates = config["ignored_updates"].map do |ignored_update|
        IgnoredUpdate.new(ignored_update["match"])
      end
    end

    @automerged_updates = []
    unless config["automerged_updates"].nil?
      @automerged_updates = config["automerged_updates"].map do |automerged_update|
        AutomergedUpdate.new(automerged_update["match"])
      end
    end

    @group_updates = [GroupUpdate.new({ "dependency_name" => "*" })]
    unless config["group_updates"].nil?
      @group_updates = config["group_updates"].map do |group_update|
        GroupUpdate.new(group_update["match"])
      end
    end

    @commit_message = {}
    unless config["commit_message"].nil?
      @commit_message = CommitMessage.new(config["commit_message"]).to_h
    end
  end

  attr_reader :package_manager
  attr_reader :directory
  attr_reader :update_schedule
  attr_reader :target_branch
  attr_reader :ignored_updates
  attr_reader :automerged_updates
  attr_reader :group_updates
  attr_reader :commit_message

  class IgnoredUpdate
    def initialize(config)
      @dependency_name = config["dependency_name"]
      @version_requirement = config["version_requirement"]
    end

    attr_reader :dependency_name
    attr_reader :version_requirement
  end

  class AutomergedUpdate
    def initialize(config)
      @dependency_name = config["dependency_name"]
      @dependency_type = config["dependency_type"]
      @update_type = config["update_type"]
    end

    attr_reader :dependency_name
    attr_reader :dependency_type
    attr_reader :update_type
  end

  class GroupUpdate
    def initialize(config)
      @dependency_name = config["dependency_name"]
    end

    attr_reader :dependency_name
  end

  class CommitMessage
    def initialize(config)
      @prefix = config["prefix"]
      @prefix_development = config["prefix_development"]
      @include_scope = config["include_scope"]
    end

    attr_reader :prefix
    attr_reader :prefix_development
    attr_reader :include_scope

    def to_h
      {
        prefix: @prefix,
        prefix_development: @prefix_development,
        include_scope: @include_scope
      }
    end
  end
end

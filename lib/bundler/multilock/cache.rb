# frozen_string_literal: true

require_relative "ui/capture"

module Bundler
  module Multilock
    # caches lockfiles across multiple lockfile checks or sync runs
    class Cache
      def initialize
        @contents = {}
        @parsers = {}
        @specs = {}
        @reverse_dependencies = {}
        @reverse_requirements = {}
        @dependent_requirements = {}
        @base_checks = {}
        @deep_checks = {}
        @dependency_options = {}
        @base_check_messages = {}
        @deep_check_messages = {}
        @missing_specs = Set.new
        @logged_missing = false
      end

      # Removes a given lockfile's associated cached data
      #
      # Should be called if the lockfile is modified
      # @param lockfile_name [Pathname]
      # @return [void]
      def invalidate_lockfile(lockfile_name)
        @contents.delete(lockfile_name)
        @parsers.delete(lockfile_name)
        @specs.delete(lockfile_name)
        @reverse_dependencies.delete(lockfile_name)
        @reverse_requirements.delete(lockfile_name)
        @dependent_requirements.delete(lockfile_name)
        invalidate_checks(lockfile_name)
      end

      def invalidate_checks(lockfile_name)
        @base_checks.delete(lockfile_name)
        @base_check_messages.delete(lockfile_name)
        # must clear them all; downstream lockfiles may depend on the state of this lockfile
        @deep_checks.clear
        @deep_check_messages.clear
      end

      # @param lockfile_name [Pathname]
      # @param options [Hash<String, Array<Hash>>]
      #   how the lockfile's Gemfile limits the dependencies that have `platforms:` or `force_ruby_platform`, by
      #   gem name, with a hash for each time the gem is declared. `:force_ruby` is if only the source variant is
      #   used, and `:platforms` is the lockfile's platforms that it's for (or nil for all of them)
      # @return [void]
      def record_dependency_options(lockfile_name, options)
        @dependency_options[lockfile_name] = options
      end

      # (known once the lockfile's Gemfile has been evaluated by the base check)
      #
      # @param lockfile_name [Pathname]
      # @return [Hash<String, Array<Hash>>] see {#record_dependency_options}
      def dependency_options(lockfile_name)
        @dependency_options.fetch(lockfile_name) { {} }
      end

      # @param lockfile_name [Pathname]
      # @return [String] the raw contents of the lockfile
      def contents(lockfile_name)
        @contents.fetch(lockfile_name) do
          @contents[lockfile_name] = lockfile_name.file? && lockfile_name.read.freeze
        end
      end

      # @param lockfile_name [Pathname]
      # @return [LockfileParser]
      def parser(lockfile_name)
        @parsers[lockfile_name] ||= LockfileParser.new(contents(lockfile_name))
      end

      def specs(lockfile_name)
        @specs[lockfile_name] ||= begin
          specs = {}
          parser(lockfile_name).specs.each do |spec|
            (specs[spec.name] ||= {})[spec.platform] = spec
          end
          specs
        end
      end

      # sometimes a gem changes platforms with a new version, such as from aarch64-linux
      # to aarch64-linux-gnu. we need to still sync it
      def find_matching_spec(specs, spec)
        specs = self.specs(specs) unless specs.is_a?(Hash)
        platform_specs = specs[spec.name]
        return unless platform_specs

        parent_spec = platform_specs[spec.platform]
        parent_spec ||= platform_specs.find { |platform, _| platform =~ spec.platform }&.last
        parent_spec || platform_specs.find { |platform, _| platform == "ruby" }&.last
      end

      # @param lockfile_name [Pathname]
      # @return [Hash<String, Set<String>>] hash of gem name to set of gem names that depend on it
      def reverse_dependencies(lockfile_name)
        ensure_reverse_data(lockfile_name)
        @reverse_dependencies[lockfile_name]
      end

      # @param lockfile_name [Pathname]
      # @return [Hash<String, Gem::Requirement>] hash of gem name to requirement for that gem
      def reverse_requirements(lockfile_name)
        ensure_reverse_data(lockfile_name)
        @reverse_requirements[lockfile_name]
      end

      # The gems in a lockfile whose requirements a version of a gem doesn't satisfy, other than
      # the gems that are being ignored (like because they're going to change themselves).
      #
      # Requirements from the lockfile's own dependencies (the Gemfile) are never ignored.
      #
      # @param lockfile_name [Pathname]
      # @param name [String] the gem's name
      # @param version [Gem::Version]
      # @param ignored_dependents [Set<String>] names of gems whose requirements shouldn't be considered
      # @param retained [Set<LazySpecification>] variants of gems that are still considered, even if the gem is ignored
      # @param gemfile_requirements [Hash<String, Gem::Requirement>, nil]
      #   the requirements of the lockfile's Gemfile, if they might be different from what's in the lockfile
      # @return [Array<String, nil>] the names of the gems (or nil, for the Gemfile)
      def blocking_dependents(lockfile_name,
                              name,
                              version,
                              ignored_dependents,
                              retained: nil,
                              gemfile_requirements: nil)
        ensure_reverse_data(lockfile_name)
        blocking = []
        @dependent_requirements[lockfile_name][name].each do |dependent, requirement, spec|
          next if ignored_dependents.include?(dependent) && !retained&.include?(spec)
          # (the lockfile's version of the Gemfile's requirements is replaced below)
          next if dependent.nil? && gemfile_requirements

          blocking << dependent unless requirement.satisfied_by?(version)
        end
        blocking << nil if gemfile_requirements&.key?(name) && !gemfile_requirements[name].satisfied_by?(version)
        blocking.uniq
      end

      # @param lockfile_name [Pathname]
      # @param name [String] the gem's name
      # @param version [Gem::Version]
      # @return [true, false] if a version of a gem satisfies everything in a lockfile that requires it
      def requirements_satisfied?(lockfile_name, name, version)
        reverse_requirements(lockfile_name)[name].satisfied_by?(version)
      end

      def conflicting_requirements?(lockfile1_name, lockfile2_name, spec1, spec2)
        reverse_requirements1 = reverse_requirements(lockfile1_name)[spec1.name]
        reverse_requirements2 = reverse_requirements(lockfile2_name)[spec1.name]

        !reverse_requirements1.satisfied_by?(spec2.version) &&
          !reverse_requirements2.satisfied_by?(spec1.version)
      end

      def log_missing_spec(spec)
        return if @missing_specs.include?(spec)

        Bundler.ui.error "The following gems are missing" if @missing_specs.empty?
        @missing_specs << spec
        Bundler.ui.error(" * #{spec.name} (#{spec.version})")
      end

      %i[base deep].each do |type|
        class_eval <<~RUBY, __FILE__, __LINE__ + 1 # rubocop:disable Style/DocumentDynamicEvalDefinition
          def #{type}_check(lockfile_name)
            if @#{type}_checks.key?(lockfile_name)
              @#{type}_check_messages[lockfile_name].replay
              @#{type}_checks[lockfile_name]
            else
              result = nil
              messages = Bundler::Multilock::UI::Capture.capture do
                result = @#{type}_checks[lockfile_name] = yield
              end
              @#{type}_check_messages[lockfile_name] = messages.tap(&:replay)
              result
            end
          end
        RUBY
      end

      private

      def ensure_reverse_data(lockfile_name)
        return if @reverse_requirements.key?(lockfile_name)

        # can use Gem::Requirement.default_prelease when Ruby 2.6 support is dropped
        reverse_requirements = Hash.new { |h, k| h[k] = Gem::Requirement.new(">= 0.a") }
        reverse_dependencies = Hash.new { |h, k| h[k] = Set.new }
        # name => [[dependent name, Gem::Requirement, dependent spec]] (nil for the lockfile's own dependencies)
        dependent_requirements = Hash.new { |h, k| h[k] = [] }

        lockfile = parser(lockfile_name)

        lockfile.dependencies.each_value do |dep|
          reverse_requirements[dep.name].requirements.concat(dep.requirement.requirements)
          dependent_requirements[dep.name] << [nil, dep.requirement, nil]
        end
        lockfile.specs.each do |spec|
          spec.dependencies.each do |dep|
            reverse_requirements[dep.name].requirements.concat(dep.requirement.requirements)
            reverse_dependencies[dep.name] << spec.name
            dependent_requirements[dep.name] << [spec.name, dep.requirement, spec]
          end
        end

        @reverse_requirements[lockfile_name] = reverse_requirements
        @reverse_dependencies[lockfile_name] = reverse_dependencies
        @dependent_requirements[lockfile_name] = dependent_requirements
      end
    end
  end
end

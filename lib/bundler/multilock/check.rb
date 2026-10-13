# frozen_string_literal: true

require_relative "cache"

module Bundler
  module Multilock
    class Check
      class << self
        def run
          new.run
        end
      end

      # @param check_installed [true, false]
      #   If gems must be installed (not just locked) for a lockfile to be valid.
      #   `bundle lock` doesn't install anything, so it shouldn't care.
      def initialize(cache = Cache.new, check_installed: true)
        @cache = cache
        @check_installed = check_installed
      end

      def run(skip_base_checks: false)
        return true unless Bundler.default_lockfile(force_original: true).exist?

        success = true
        unless skip_base_checks
          default_lockfile_definition = Multilock.default_lockfile_definition
          default_lockfile_definition ||= { gemfile: Bundler.default_gemfile,
                                            lockfile: Bundler.default_lockfile(force_original: true) }
          base_check(default_lockfile_definition)
        end
        Multilock.lockfile_definitions.each do |lockfile_name, lockfile_definition|
          next if lockfile_name == Bundler.default_lockfile(force_original: true)

          unless lockfile_name.exist?
            Bundler.ui.error("Lockfile #{lockfile_name} does not exist.")
            success = false
            next
          end

          success &&= base_check(lockfile_definition) && deep_check(lockfile_definition)
        end
        success
      end

      # this is mostly equivalent to the built in checks in `bundle check`, but even
      # more conservative, and returns false instead of exiting on failure
      def base_check(lockfile_definition, check_missing_deps: false)
        lockfile_name = lockfile_definition[:lockfile]
        default_root = Bundler.root

        result = @cache.base_check(lockfile_name) do
          next false unless lockfile_name.file?

          Multilock.prepare_block = lockfile_definition[:prepare]
          # root needs to be set so that paths are output relative to the correct root in the lockfile
          Bundler.root = lockfile_definition[:gemfile].dirname

          lockfile_path = lockfile_name.relative_path_from(Dir.pwd)
          gemfile_path = lockfile_definition[:gemfile].relative_path_from(Dir.pwd)

          # (as the default lockfile, so that it isn't swapped for the active one)
          definition = Bundler.with_default_lockfile(lockfile_name) do
            Definition.build(lockfile_definition[:gemfile], lockfile_name, false)
          end
          unless definition.send(:current_platform_locked?)
            next base_check_failed("#{lockfile_path} does not include the current platform " \
                                   "(#{Bundler.local_platform}).")
          end
          # the lockfile's sources don't match the Gemfile's (like a different
          # git remote); also, resolving would try to fetch the new source
          if definition.instance_variable_get(:@source_changes)
            next base_check_failed(source_changes_message(definition, lockfile_path, gemfile_path))
          end

          begin
            definition.validate_runtime!
            not_installed = @check_installed ? Bundler.ui.silence { definition.missing_specs } : []
          rescue RubyVersionMismatch, GemNotFound, SolveFailure, GitError => e
            next base_check_failed("Could not check #{lockfile_path}: #{e.message}")
          end

          if Bundler.ui.error?
            not_installed.each do |spec|
              @cache.log_missing_spec(spec)
            end
          end

          next false unless not_installed.empty?
          # without checking installed gems, nothing above notices a dependency
          # that was added to the Gemfile but isn't locked yet
          unless @check_installed || definition.no_resolve_needed?
            next base_check_failed("#{lockfile_path} is out of date, because #{definition.send(:change_reason)}.")
          end

          # (and even when checking installed gems, a dependency like a path gem
          # or plugin can be "installed" without being locked)
          unlocked = definition.dependencies.map(&:name) - definition.locked_gems.dependencies.keys
          unless unlocked.empty?
            next base_check_failed("#{lockfile_path} is missing dependencies from #{gemfile_path}: " \
                                   "#{unlocked.join(", ")}.")
          end

          # cache a sentinel so that we can share a cache regardless of the check_missing_deps argument
          next :missing_deps unless (definition.locked_gems.dependencies.values - definition.dependencies).empty?

          true
        end

        return !check_missing_deps if result == :missing_deps

        result
      ensure
        Multilock.prepare_block = nil
        Bundler.root = default_root
      end

      # @return [false]
      def base_check_failed(message) # rubocop:disable Naming/PredicateMethod -- not a predicate
        Bundler.ui.error(message)
        false
      end

      def source_changes_message(definition, lockfile_path, gemfile_path)
        locked = definition.locked_gems.sources
        current = definition.send(:sources).lock_sources
        only_locked = locked.reject { |source| current.include?(source) }
        only_current = current.reject { |source| locked.include?(source) }

        message = "The sources in #{lockfile_path} do not match #{gemfile_path}."
        message << "\n  Only in #{lockfile_path}: #{only_locked.join(", ")}" unless only_locked.empty?
        message << "\n  Only in #{gemfile_path}: #{only_current.join(", ")}" unless only_current.empty?
        message
      end

      # checks that every gem has a checksum, and that gems in common (same version
      # and source) with the parent lockfile have the same checksums
      def checksums_valid?(parser, parent_parser, lockfile_path)
        parent_specs = parent_parser.specs.to_h { |spec| [spec.full_name, spec] }
        invalid = parser.specs.select do |spec|
          next false unless spec.source.is_a?(Source::Rubygems)

          checksums = spec.source.checksum_store.checksums_to_lock(spec.full_name)
          unless checksums
            Bundler.ui.error("#{lockfile_path} is missing a checksum for #{spec.lock_name}.")
            next true
          end

          parent_spec = parent_specs[spec.full_name]
          next false unless parent_spec && parent_spec.source == spec.source

          parent_checksums = parent_spec.source.checksum_store.checksums_to_lock(spec.full_name)
          next false if parent_checksums.nil? || checksums == parent_checksums

          Bundler.ui.error("The checksum for #{spec.lock_name} in #{lockfile_path} " \
                           "does not match the parent lockfile's (#{parent_checksums}).")
          true
        end
        invalid.empty?
      end

      # this checks for mismatches between the parent lockfile and the given lockfile,
      # and for pinned dependencies in lockfiles requiring them
      def deep_check(lockfile_definition, conflicts: nil)
        lockfile_name = lockfile_definition[:lockfile]
        @cache.deep_check(lockfile_name) do
          success = true
          proven_pinned = Set.new
          needs_pin_check = []
          parser = @cache.parser(lockfile_name)
          lockfile_path = lockfile_name.relative_path_from(Dir.pwd)
          parent_lockfile_name = lockfile_definition[:parent]
          parent_parser = @cache.parser(parent_lockfile_name)
          unless parser.platforms == parent_parser.platforms
            Bundler.ui.error("The platforms in #{lockfile_path} do not match the parent lockfile.")
            success = false
          end
          unless parser.bundler_version == parent_parser.bundler_version
            Bundler.ui.error("bundler (#{parser.bundler_version}) in #{lockfile_path} " \
                             "does not match the parent lockfile's version (@#{parent_parser.bundler_version}).")
            success = false
          end
          unless parser.ruby_version == parent_parser.ruby_version
            Bundler.ui.error("ruby (#{parser.ruby_version || "<none>"}) in #{lockfile_path} " \
                             "does not match the parent lockfile's version (#{parent_parser.ruby_version}).")
            success = false
          end
          unless !parser.checksums == !parent_parser.checksums
            Bundler.ui.error("The parent lockfile #{parent_parser.checksums ? "has" : "does not have"} checksums, " \
                             "but #{lockfile_path} #{parser.checksums ? "does" : "does not"}.")
            success = false
          end
          if parser.checksums && parent_parser.checksums && !checksums_valid?(parser, parent_parser, lockfile_path)
            success = false
          end

          # look through top-level explicit dependencies for pinned requirements
          if lockfile_definition[:enforce_pinned_additional_dependencies]
            find_pinned_dependencies(proven_pinned, parser.dependencies.each_value)
          end

          # check for conflicting requirements (and build list of pins, in the same loop)
          parser.specs.each do |spec|
            parent_spec = @cache.find_matching_spec(parent_lockfile_name, spec)

            if lockfile_definition[:enforce_pinned_additional_dependencies]
              # look through what this spec depends on, and keep track of all pinned requirements
              find_pinned_dependencies(proven_pinned, spec.dependencies)

              needs_pin_check << spec unless parent_spec
            end

            next unless parent_spec

            # have to ensure Path sources are relative to their lockfile before comparing
            same_source = if [parent_spec.source, spec.source].grep(Source::Path).length == 2
                            lockfile_name
                              .dirname
                              .join(spec.source.path)
                              .ascend
                              .any?(parent_lockfile_name.dirname.join(parent_spec.source.path))
                          else
                            parent_spec.source == spec.source
                          end

            next if parent_spec.version == spec.version && same_source

            # the version in the parent lockfile cannot possibly satisfy the requirements
            # in this lockfile, and vice versa, so we assume it's intentional and allow it
            if @cache.conflicting_requirements?(lockfile_name, parent_lockfile_name, spec, parent_spec)
              # we're allowing it to differ from the parent, so pin check requirement comes into play
              needs_pin_check << spec if lockfile_definition[:enforce_pinned_additional_dependencies]
              next
            end

            Bundler.ui.error("#{spec}#{spec.git_version} in #{lockfile_path} " \
                             "does not match the parent lockfile's version " \
                             "(@#{parent_spec.version}#{parent_spec.git_version}); " \
                             "this may be due to a conflicting requirement, which would require manual resolution.")
            conflicts&.add(spec.name)
            success = false
          end

          # now that we have built a list of every gem that is pinned, go through
          # the gems that were in this lockfile, but not the parent lockfile, and
          # ensure it's pinned _somehow_
          needs_pin_check.each do |spec|
            pinned = case spec.source
                     when Source::Git
                       spec.source.ref == spec.source.revision
                     when Source::Path
                       true
                     when Source::Rubygems
                       proven_pinned.include?(spec.name)
                     else
                       false
                     end

            next if pinned

            message = "#{spec} in #{lockfile_path} has not been pinned to a specific version,  " \
                      "which is required since it is not part of the parent lockfile."
            message << " Be sure to set the ref to a commit hash for git sources." if spec.source.is_a?(Source::Git)
            Bundler.ui.error(message)
            success = false
          end

          success
        end
      end

      private

      def find_pinned_dependencies(proven_pinned, dependencies)
        dependencies.each do |dependency|
          dependency.requirement.requirements.each do |requirement|
            proven_pinned << dependency.name if requirement.first == "="
          end
        end
      end
    end
  end
end

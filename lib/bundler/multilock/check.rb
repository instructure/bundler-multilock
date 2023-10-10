# frozen_string_literal: true

require "set"

module Bundler
  module Multilock
    class Check
      attr_reader :lockfiles, :lockfile_contents, :lockfile_specs

      class << self
        def run
          new.run
        end
      end

      def initialize
        @lockfiles = {}
        @lockfile_contents = {}
        @lockfile_specs = {}
      end

      def load_lockfile(lockfile)
        return if lockfile_contents.key?(lockfile)

        contents = lockfile_contents[lockfile] = lockfile.read.freeze
        parser = lockfiles[lockfile] = LockfileParser.new(contents)
        lockfile_specs[lockfile] = parser.specs.to_h do |spec|
          [[spec.name, spec.platform], spec]
        end
      end

      def run(skip_base_checks: false)
        return true unless Bundler.default_lockfile(force_original: true).exist?

        success = true
        unless skip_base_checks
          missing_specs = base_check({ gemfile: Bundler.default_gemfile,
                                       lockfile: Bundler.default_lockfile(force_original: true) },
                                     return_missing: true).to_set
        end
        Multilock.lockfile_definitions.each do |lockfile_definition|
          next if lockfile_definition[:lockfile] == Bundler.default_lockfile(force_original: true)

          unless lockfile_definition[:lockfile].exist?
            Bundler.ui.error("Lockfile #{lockfile_definition[:lockfile]} does not exist.")
            success = false
          end

          unless skip_base_checks
            new_missing = base_check(lockfile_definition, log_missing: missing_specs, return_missing: true)
            success = false unless new_missing.empty?
            missing_specs.merge(new_missing)
          end
          success = false unless check(lockfile_definition)
        end
        success
      end

      # this is mostly equivalent to the built in checks in `bundle check`, but even
      # more conservative, and returns false instead of exiting on failure
      def base_check(lockfile_definition, log_missing: false, return_missing: false, check_missing_deps: false)
        return return_missing ? [] : false unless lockfile_definition[:lockfile].file?

        Multilock.prepare_block = lockfile_definition[:prepare]
        definition = Definition.build(lockfile_definition[:gemfile], lockfile_definition[:lockfile], false)
        return return_missing ? [] : false unless definition.send(:current_platform_locked?)

        begin
          definition.validate_runtime!
          not_installed = Bundler.ui.silence { definition.missing_specs }
        rescue RubyVersionMismatch, GemNotFound, SolveFailure
          return return_missing ? [] : false
        end

        if log_missing
          not_installed.each do |spec|
            next if log_missing.include?(spec)

            Bundler.ui.error "The following gems are missing" if log_missing.empty?
            Bundler.ui.error(" * #{spec.name} (#{spec.version})")
          end
        end

        return not_installed if return_missing

        return false unless not_installed.empty? && definition.no_resolve_needed?
        return true unless check_missing_deps

        (definition.locked_gems.dependencies.values - definition.dependencies).empty?
      ensure
        Multilock.prepare_block = nil
      end

      # this checks for mismatches between the parent lockfile and the given lockfile,
      # and for pinned dependencies in lockfiles requiring them
      def check(lockfile_definition)
        success = true
        proven_pinned = Set.new
        needs_pin_check = []
        lockfile = LockfileParser.new(lockfile_definition[:lockfile].read)
        lockfile_path = lockfile_definition[:lockfile].relative_path_from(Dir.pwd)
        parent = lockfile_definition[:parent]
        load_lockfile(parent)
        parent_lockfile = lockfiles[parent]
        unless lockfile.platforms == parent_lockfile.platforms
          Bundler.ui.error("The platforms in #{lockfile_path} do not match the parent lockfile.")
          success = false
        end
        unless lockfile.bundler_version == parent_lockfile.bundler_version
          Bundler.ui.error("bundler (#{lockfile.bundler_version}) in #{lockfile_path} " \
                           "does not match the parent lockfile's version (@#{parent_lockfile.bundler_version}).")
          success = false
        end

        reverse_dependencies = cache_reverse_dependencies(lockfile)
        parent_reverse_dependencies = cache_reverse_dependencies(parent_lockfile)

        # look through top-level explicit dependencies for pinned requirements
        if lockfile_definition[:enforce_pinned_additional_dependencies]
          find_pinned_dependencies(proven_pinned, lockfile.dependencies.each_value)
        end

        # check for conflicting requirements (and build list of pins, in the same loop)
        lockfile.specs.each do |spec|
          parent_spec = lockfile_specs[parent][[spec.name, spec.platform]]

          if lockfile_definition[:enforce_pinned_additional_dependencies]
            # look through what this spec depends on, and keep track of all pinned requirements
            find_pinned_dependencies(proven_pinned, spec.dependencies)

            needs_pin_check << spec unless parent_spec
          end

          next unless parent_spec

          # have to ensure Path sources are relative to their lockfile before comparing
          same_source = if [parent_spec.source, spec.source].grep(Source::Path).length == 2
                          lockfile_definition[:lockfile]
                            .dirname
                            .join(spec.source.path)
                            .ascend
                            .any?(parent.dirname.join(parent_spec.source.path))
                        else
                          parent_spec.source == spec.source
                        end

          next if parent_spec.version == spec.version && same_source

          # the version in the parent lockfile cannot possibly satisfy the requirements
          # in this lockfile, and vice versa, so we assume it's intentional and allow it
          unless reverse_dependencies[spec.name].satisfied_by?(parent_spec.version) ||
                 parent_reverse_dependencies[spec.name].satisfied_by?(spec.version)
            # we're allowing it to differ from the parent, so pin check requirement comes into play
            needs_pin_check << spec if lockfile_definition[:enforce_pinned_additional_dependencies]
            next
          end

          Bundler.ui.error("#{spec}#{spec.git_version} in #{lockfile_path} " \
                           "does not match the parent lockfile's version " \
                           "(@#{parent_spec.version}#{parent_spec.git_version}); " \
                           "this may be due to a conflicting requirement, which would require manual resolution.")
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

          Bundler.ui.error("#{spec} in #{lockfile_path} has not been pinned to a specific version,  " \
                           "which is required since it is not part of the parent lockfile.")
          success = false
        end

        success
      end

      private

      def cache_reverse_dependencies(lockfile)
        reverse_dependencies = Hash.new { |h, k| h[k] = Gem::Requirement.default_prerelease }

        lockfile.dependencies.each_value do |spec|
          reverse_dependencies[spec.name].requirements.concat(spec.requirement.requirements)
        end
        lockfile.specs.each do |spec|
          spec.dependencies.each do |dependency|
            reverse_dependencies[dependency.name].requirements.concat(dependency.requirement.requirements)
          end
        end

        reverse_dependencies
      end

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

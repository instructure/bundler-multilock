# frozen_string_literal: true

module Bundler
  module Multilock
    module Ext
      module Dsl
        module ClassMethods
          ::Bundler::Dsl.singleton_class.prepend(self)

          # Significant changes:
          #  * evaluate the prepare block as part of the gemfile
          #  * keep track of the ruby version set in the default gemfile
          #  * apply that ruby version to alternate lockfiles if they didn't set one
          #    themselves
          #  * mark Multilock as loaded once the main gemfile is evaluated
          #    so that they're not loaded multiple times
          #  * ignore a lockfile that Bundler derived from BUNDLE_LOCKFILE
          #    before Multilock was loaded
          #  * when evaluating again after Multilock is loaded (`lockfile` no
          #    longer does anything then), still include the lockfile's block
          def evaluate(gemfile, lockfile, unlock)
            if !Multilock.loaded? &&
               (env_lockfile = ENV.fetch("BUNDLE_LOCKFILE", nil)) &&
               lockfile.to_s == env_lockfile
              lockfile = Bundler.default_lockfile(force_original: true)
            end

            builder = new
            prepare_block = Multilock.prepare_block
            prepare_block ||= Multilock.lockfile_definitions.dig(lockfile, :prepare) if Multilock.loaded?
            builder.eval_gemfile(gemfile, &prepare_block) if prepare_block
            builder.eval_gemfile(gemfile)
            if (ruby_version_requirement = builder.instance_variable_get(:@ruby_version)) &&
               Multilock.lockfile_definitions[lockfile]
              Multilock.lockfile_definitions[lockfile][:ruby_version_requirement] = ruby_version_requirement
            elsif (parent_lockfile = Multilock.lockfile_definitions.dig(lockfile, :parent)) &&
                  (parent_lockfile_definition = Multilock.lockfile_definitions[parent_lockfile]) &&
                  (parent_ruby_version_requirement = parent_lockfile_definition[:ruby_version_requirement])
              builder.instance_variable_set(:@ruby_version, parent_ruby_version_requirement)
            end
            Multilock.loaded!
            builder.to_definition(lockfile, unlock)
          end
        end

        ::Bundler::Dsl.prepend(self)

        def initialize
          super
          @gemfiles = Set.new
          Multilock.loaded! unless Multilock.lockfile_definitions.empty?
        end

        # Significant changes:
        #  * allow a block
        def eval_gemfile(gemfile, contents = nil, &block)
          expanded_gemfile_path = Pathname.new(gemfile).expand_path(@gemfile&.parent)
          original_gemfile = @gemfile
          @gemfile = expanded_gemfile_path
          @gemfiles << expanded_gemfile_path
          contents ||= Bundler.read_file(@gemfile.to_s)
          if block
            instance_eval(&block)
          else
            instance_eval(contents.dup, @gemfile.to_s, 1)
          end
        rescue Exception => e # rubocop:disable Lint/RescueException
          message = "There was an error " \
                    "#{e.is_a?(GemfileEvalError) ? "evaluating" : "parsing"} " \
                    "`#{File.basename gemfile.to_s}`: #{e.message}"

          raise Bundler::Dsl::DSLError.new(message, gemfile.to_s, e.backtrace, contents)
        ensure
          @gemfile = original_gemfile
        end

        # Significant changes:
        #  * in a Gemfile we switched to (see #allow_duplicate_plugins_in), don't
        #    warn the first time a plugin that's already declared is declared again
        def plugin(name, *args)
          unless @duplicate_plugins_gemfile &&
                 @gemfile == @duplicate_plugins_gemfile &&
                 !@allowed_duplicate_plugins.include?(name) &&
                 @dependencies.any? { |dependency| dependency.name == name }
            return super
          end

          @allowed_duplicate_plugins << name
          # Bundler only warns about it (instead of raising) if the version
          # requirements and the source match exactly
          Bundler.ui.silence { super }
        end

        # @!visibility private
        # Allows plugins to be declared again, once each, in the given Gemfile,
        # without Bundler warning that they're listed more than once
        def allow_duplicate_plugins_in(gemfile)
          @duplicate_plugins_gemfile = Pathname.new(gemfile).expand_path
          @allowed_duplicate_plugins = Set.new
        end

        def lockfile(*, **, &)
          return true if Multilock.loaded?

          Multilock.add_lockfile(*, builder: self, **, &)
        end
      end
    end
  end
end

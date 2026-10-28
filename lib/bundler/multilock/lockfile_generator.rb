# frozen_string_literal: true

require "delegate"

require "bundler/lockfile_generator"

module Bundler
  module Multilock
    # generates a lockfile based on another LockfileParser
    class LockfileGenerator < Bundler::LockfileGenerator
      def self.generate(lockfile)
        new(LockfileAdapter.new(lockfile)).generate!
      end

      private

      class LockfileAdapter < SimpleDelegator
        def sources
          self
        end

        def lock_sources
          __getobj__.sources
        end

        def resolve
          specs
        end

        def dependencies
          super.values
        end

        def locked_ruby_version
          ruby_version
        end

        def locked_checksums
          checksums
        end

        # Bundler 4.1 asks the definition about the lockfile it's replacing;
        # here the adapted lockfile is both the old and the new one.
        def locked_gems
          __getobj__
        end

        def overrides_to_lock
          Array(overrides).map(&:to_lock).uniq
        end

        def bundler_version_to_lock
          bundler_version
        end
      end

      private_constant :LockfileAdapter

      def add_bundled_with
        add_section("BUNDLED WITH", definition.bundler_version.to_s)
      end
    end
  end
end

# frozen_string_literal: true

module Bundler
  module Multilock
    module Ext
      module Definition
        ::Bundler::Definition.prepend(self)

        def initialize(lockfile, *args)
          # we changed the default lockfile in Bundler::Multilock.add_lockfile
          # since DSL.evaluate was called (re-entrantly); sub the proper value in
          if !lockfile.equal?(Bundler.default_lockfile) &&
             Bundler.default_lockfile(force_original: true) == lockfile
            lockfile = Bundler.default_lockfile
          end
          super
        end

        # `bundle install` sets the lockfile from BUNDLE_LOCKFILE, which Multilock handles itself
        def lockfile=(lockfile)
          lockfile = Bundler.default_lockfile if lockfile && lockfile.to_s == ENV.fetch("BUNDLE_LOCKFILE", nil)

          super
        end

        def validate_runtime!
          Multilock.loaded! unless Multilock.lockfile_definitions.empty?

          super
        end
      end
    end
  end
end

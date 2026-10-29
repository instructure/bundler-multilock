# frozen_string_literal: true

module Bundler
  module Multilock
    module Ext
      # Makes `bundle cache` (and `bundle install` when vendor/cache exists) package
      # the gems from every lockfile, and only prune gems that none of them use.
      # Likewise, `bundle clean` only removes gems that none of the lockfiles use, and the
      # `prune` setting covers the git gems from all of them.
      module Runtime
        ::Bundler::Runtime.prepend(self)

        def cache(custom_path = nil, *)
          cache_alternate_lockfiles(custom_path)
          super
        end

        def prune_cache(cache_path)
          return super if multilock_alternate_definitions.empty?

          ensure_multilock_cache_path(cache_path)

          resolve = [@definition, *multilock_alternate_definitions].flat_map { |definition| definition.resolve.to_a }
          prune_gem_cache(resolve, cache_path)
          prune_git_and_path_cache(resolve, cache_path)
        end

        # Bundler's `clean` only keeps what the one definition needs, so keep what all of them need.
        # It also keys the specs it keeps by name, which would drop all but one version of a gem
        # that the lockfiles disagree on, so that's replaced for the duration. (Keyed by where they
        # are installed, since different lockfiles can lock different revisions of the same git gem.)
        def clean(*)
          alternate_definitions = multilock_alternate_definitions
          return super if alternate_definitions.empty?

          combined = [specs, *alternate_definitions.map(&:specs)].flat_map(&:to_a)
          rubygems = Bundler.rubygems
          original_add_default_gems_to = rubygems.method(:add_default_gems_to)
          rubygems.define_singleton_method(:add_default_gems_to) do |_specs|
            (original_add_default_gems_to.call([]).values + combined).to_h { |spec| [spec.full_gem_path, spec] }
          end

          begin
            super
          ensure
            rubygems.singleton_class.send(:remove_method, :add_default_gems_to)
          end
        end

        private

        # Same as Bundler's, except that it also covers the git gems that only other lockfiles use
        def prune_git_metadata
          return super if multilock_alternate_definitions.empty?

          owned = "#{Bundler.install_path}#{File::SEPARATOR}"
          git_sources = [@definition, *multilock_alternate_definitions].flat_map do |definition|
            definition.sources.git_sources
          end
          git_dirs = git_sources.reject(&:local?).filter_map do |source|
            install_path = source.install_path.to_s
            next unless install_path.start_with?(owned)

            git_dir = File.join(install_path, ".git")
            git_dir if File.exist?(git_dir)
          end.uniq
          return if git_dirs.empty?

          Bundler.ui.info "Removing git metadata from checked out git gems"
          git_dirs.each do |git_dir|
            ::Bundler::SharedHelpers.filesystem_access(git_dir) do |p|
              FileUtils.rm_rf(p)
            end
          end
        end

        def ensure_multilock_cache_path(cache_path)
          return if File.exist?(cache_path)

          ::Bundler::SharedHelpers.filesystem_access(cache_path) do |p|
            FileUtils.mkdir_p(p)
          end
        end

        # @return [Array<Definition>] the definitions of the lockfiles other than the one being cached
        def multilock_alternate_definitions
          @multilock_alternate_definitions ||= Multilock.alternate_definitions
        end

        # Caches the gems that only the other lockfiles use. The ones in common are cached by the
        # usual process, which also cleans up git sources and prunes afterwards.
        def cache_alternate_lockfiles(custom_path)
          return if multilock_alternate_definitions.empty?

          cache_path = Bundler.app_cache(custom_path)
          ensure_multilock_cache_path(cache_path)

          cached = Set.new
          multilock_alternate_definitions.each do |definition|
            specs_to_cache = if Bundler.settings[:cache_all_platforms]
                               definition.resolve.materialized_for_all_platforms
                             else
                               definition.specs
                             end

            specs_to_cache.each do |spec|
              next if spec.name == "bundler"

              source = spec.source
              next if source.is_a?(::Bundler::Source::Gemspec)

              # git sources are equal regardless of which revision is locked, but each one
              # is cached separately
              cache_key = source.respond_to?(:app_cache_dirname) ? source.app_cache_dirname : source
              next unless cached.add?([spec.full_name, cache_key])

              if source.respond_to?(:migrate_cache)
                source.migrate_cache(custom_path, local: false)
              elsif source.respond_to?(:cache)
                # like Bundler, leave path gems that are inside the project alone, even when they're
                # outside the directory of the Gemfile that declared them
                next if source.is_a?(::Bundler::Source::Path) &&
                        source.send(:expanded_original_path).to_s.start_with?("#{Bundler.root}/")

                if source.respond_to?(:root_path) && source.root_path.exist?
                  # (it also memoizes the cache path while Bundler.root is that Gemfile's directory)
                  source.instance_variable_set(:@app_cache_path, cache_path.join(source.app_cache_dirname))
                  Dir.chdir(source.root_path) { source.cache(spec, custom_path) }
                else
                  source.cache(spec, custom_path)
                end
              end
            end
          end
        end
      end
    end
  end
end

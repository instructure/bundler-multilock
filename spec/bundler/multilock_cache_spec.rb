# frozen_string_literal: true

describe Bundler::Multilock do
  describe "bundle cache" do
    def cached_gems
      Dir["vendor/cache/*.gem"].map { |path| File.basename(path, ".gem") }.sort
    end

    it "caches the gems from every lockfile, including differing versions" do
      with_gemfile(<<~RUBY) do
        lockfile do
          gem "rake", "13.2.1"
        end

        lockfile "Gemfile.alt.lock" do
          gem "rake", "13.1.0"
          gem "concurrent-ruby", "1.2.2"
        end
      RUBY
        use_local_bundle_path
        invoke_bundler("install")
        invoke_bundler("cache")

        expect(cached_gems).to include("rake-13.2.1", "rake-13.1.0", "concurrent-ruby-1.2.2")
      end
    end

    it "caches the gems from every lockfile when an alternate lockfile is flagged as active" do
      with_gemfile(<<~RUBY) do
        lockfile(active: false) do
          gem "rake", "13.2.1"
        end

        lockfile "Gemfile.alt.lock", active: true do
          gem "rake", "13.1.0"
          gem "concurrent-ruby", "1.2.2"
        end
      RUBY
        use_local_bundle_path
        invoke_bundler("install")
        invoke_bundler("cache")

        expect(cached_gems).to include("rake-13.2.1", "rake-13.1.0", "concurrent-ruby-1.2.2")

        # and again, now that everything is cached, to make sure nothing is pruned
        invoke_bundler("cache")
        expect(cached_gems).to include("rake-13.2.1", "rake-13.1.0", "concurrent-ruby-1.2.2")
      end
    end

    # the lockfiles lock different versions of a gem that the Gemfile doesn't pin, as can happen when
    # an alternate lockfile is updated on its own
    def with_diverged_rake(gemfile)
      with_gemfile(gemfile) do
        use_local_bundle_path
        invoke_bundler("install")

        primary_version = File.read("Gemfile.lock")[/^    rake \((\d[^)]*)\)/, 1]
        expect(primary_version).not_to eq "13.1.0"
        install_local_gem("rake", "13.1.0")
        replace_lockfile_pin("Gemfile.alt.lock", "rake", "13.1.0")

        yield primary_version
      end
    end

    it "caches the implicit default lockfile's gems when an alternate lockfile is active" do
      with_diverged_rake(<<~RUBY) do |primary_version|
        gem "rake", ">= 13.0"

        lockfile "Gemfile.alt.lock", active: true do
          gem "concurrent-ruby", "1.2.2"
        end
      RUBY
        invoke_bundler("cache")

        expect(cached_gems).to include("rake-#{primary_version}", "rake-13.1.0", "concurrent-ruby-1.2.2")
      end
    end

    it "caches the default lockfile's own versions when an alternate lockfile is active" do
      with_diverged_rake(<<~RUBY) do |primary_version|
        lockfile(active: false) do
          gem "rake", ">= 13.0"
        end

        lockfile "Gemfile.alt.lock", active: true do
          gem "rake", ">= 13.0"
          gem "concurrent-ruby", "1.2.2"
        end
      RUBY
        invoke_bundler("cache")

        expect(cached_gems).to include("rake-#{primary_version}", "rake-13.1.0", "concurrent-ruby-1.2.2")
      end
    end

    it "leaves out the gems from groups excluded by `only`, in every lockfile" do
      with_gemfile(<<~RUBY) do
        lockfile do
          gem "rake", "13.2.1"
        end

        lockfile "Gemfile.alt.lock" do
          gem "rake", "13.1.0"

          group :extra do
            gem "concurrent-ruby", "1.2.2"
          end
        end
      RUBY
        use_local_bundle_path
        invoke_bundler("install")
        invoke_bundler("config set --local only default")
        invoke_bundler("cache")

        expect(cached_gems).to include("rake-13.2.1", "rake-13.1.0")
        expect(cached_gems).not_to include("concurrent-ruby-1.2.2")
      end
    end

    it "doesn't prune cached gems from groups excluded by `without`, like Bundler" do
      with_gemfile(<<~RUBY) do
        lockfile do
          gem "rake", "13.2.1"
        end

        lockfile "Gemfile.alt.lock" do
          gem "rake", "13.1.0"

          group :extra do
            gem "concurrent-ruby", "1.2.2"
          end
        end
      RUBY
        use_local_bundle_path
        invoke_bundler("install")
        invoke_bundler("cache")
        expect(cached_gems).to include("concurrent-ruby-1.2.2")

        invoke_bundler("config set --local without extra")
        invoke_bundler("cache")

        expect(cached_gems).to include("rake-13.2.1", "rake-13.1.0", "concurrent-ruby-1.2.2")
      end
    end

    it "caches different locked revisions of the same git gem from different lockfiles" do
      Dir.mktmpdir do |repo|
        revisions = Dir.chdir(repo) do
          create_local_gem("multi_rev_gem", subdirectory: false)
          git = "git -c user.name=test -c user.email=test@example.com"
          system("git init -q -b main && git add -A && #{git} commit -q -m one", exception: true)
          first = `git rev-parse HEAD`.strip
          File.write("changed.txt", "second revision")
          system("git add -A && #{git} commit -q -m two", exception: true)
          [first, `git rev-parse HEAD`.strip]
        end

        with_gemfile(<<~RUBY) do
          lockfile do
            gem "rake", "13.2.1"
          end

          lockfile "Gemfile.one.lock" do
            gem "multi_rev_gem", git: #{repo.inspect}, branch: "main"
          end

          lockfile "Gemfile.two.lock" do
            gem "multi_rev_gem", git: #{repo.inspect}, branch: "main"
          end
        RUBY
          use_local_bundle_path
          invoke_bundler("install")

          # the same version and branch, but locked at different commits
          replace_string("Gemfile.one.lock", /revision: \h+/, "revision: #{revisions[0]}")
          replace_string("Gemfile.two.lock", /revision: \h+/, "revision: #{revisions[1]}")
          invoke_bundler("install")
          invoke_bundler("cache")

          # (named after the repository, not the gem)
          cached_checkouts = Dir["vendor/cache/*-*"].select { |path| File.directory?(path) }
                                                    .grep(/-\h{12}\z/)
          expect(cached_checkouts.map { |path| File.basename(path)[-12..] }.sort)
            .to eq(revisions.map { |revision| revision[0, 12] }.sort)
        end
      end
    end

    it "only caches the active lockfile's gems when BUNDLE_LOCKFILE is specified" do
      with_gemfile(<<~RUBY) do
        gem "rake", "13.2.1"

        lockfile do
        end

        lockfile "Gemfile.alt.lock" do
          gem "concurrent-ruby", "1.2.2"
        end
      RUBY
        use_local_bundle_path
        invoke_bundler("install")
        invoke_bundler("cache", env: { "BUNDLE_LOCKFILE" => "Gemfile.alt.lock" })

        expect(cached_gems).to include("rake-13.2.1", "concurrent-ruby-1.2.2")

        FileUtils.rm_rf("vendor/cache")
        invoke_bundler("cache", env: { "BUNDLE_LOCKFILE" => "Gemfile.lock" })

        expect(cached_gems).to include("rake-13.2.1")
        expect(cached_gems).not_to include("concurrent-ruby-1.2.2")
      end
    end

    it "keeps gems that are in any lockfile, and prunes gems that are in none" do
      with_gemfile(<<~RUBY) do
        gem "rake", "13.2.1"

        lockfile do
        end

        lockfile "Gemfile.alt.lock" do
          gem "concurrent-ruby", "1.2.2"
        end
      RUBY
        use_local_bundle_path
        invoke_bundler("install")
        invoke_bundler("cache")
        expect(cached_gems).to include("rake-13.2.1", "concurrent-ruby-1.2.2")

        # a gem that used to be in a lockfile, but isn't any more
        install_local_gem("rake", "13.0.6")
        FileUtils.cp("#{local_gem_dir}/cache/rake-13.0.6.gem", "vendor/cache/")
        expect(cached_gems).to include("rake-13.0.6")

        # running it again (with the alternate lockfile's gems already cached) keeps them
        output = invoke_bundler("cache")

        expect(output).to include("Removing outdated .gem files")
        expect(cached_gems).to include("rake-13.2.1", "concurrent-ruby-1.2.2")
        expect(cached_gems).not_to include("rake-13.0.6")
      end
    end

    it "prunes a gem that was dropped from an alternate lockfile" do
      with_gemfile(<<~RUBY) do
        gem "rake", "13.2.1"

        lockfile do
        end

        lockfile "Gemfile.alt.lock" do
          gem "concurrent-ruby", "1.2.2"
        end
      RUBY
        use_local_bundle_path
        invoke_bundler("install")
        invoke_bundler("cache")
        expect(cached_gems).to include("concurrent-ruby-1.2.2")

        write_gemfile(<<~RUBY)
          gem "rake", "13.2.1"

          lockfile do
          end

          lockfile "Gemfile.alt.lock" do
            gem "concurrent-ruby", "1.2.1"
          end
        RUBY
        invoke_bundler("install")
        invoke_bundler("cache")

        expect(cached_gems).to include("rake-13.2.1", "concurrent-ruby-1.2.1")
        expect(cached_gems).not_to include("concurrent-ruby-1.2.2")
      end
    end

    describe "path gems that are only in an alternate lockfile" do
      def with_alternate_path_gem
        Dir.mktmpdir do |gem_dir|
          Dir.chdir(gem_dir) { create_local_gem("alt_only_gem") }

          with_gemfile(<<~RUBY) do
            lockfile do
              gem "rake", "13.2.1"
            end

            lockfile "Gemfile.alt.lock" do
              gem "alt_only_gem", path: #{File.join(gem_dir, "alt_only_gem").inspect}
            end
          RUBY
            use_local_bundle_path
            invoke_bundler("install")
            yield
          end
        end
      end

      it "caches them with BUNDLE_CACHE_ALL, and prunes ones no lockfile uses" do
        with_alternate_path_gem do
          FileUtils.mkdir_p("vendor/cache/stale_gem")
          FileUtils.touch("vendor/cache/stale_gem/.bundlecache")

          invoke_bundler("cache", env: { "BUNDLE_CACHE_ALL" => "1" })

          expect(File.directory?("vendor/cache/alt_only_gem")).to be true
          expect(File.directory?("vendor/cache/stale_gem")).to be false
          expect(cached_gems).to include("rake-13.2.1")
        end
      end

      it "caches them with `bundle config --local cache_all true`" do
        with_alternate_path_gem do
          invoke_bundler("config set --local cache_all true")
          invoke_bundler("cache")

          expect(File.directory?("vendor/cache/alt_only_gem")).to be true
          expect(cached_gems).to include("rake-13.2.1")
        end
      end

      it "caches them on `bundle install` once vendor/cache exists, with cache_all" do
        with_alternate_path_gem do
          invoke_bundler("config set --local cache_all true")
          FileUtils.mkdir_p("vendor/cache")
          invoke_bundler("install")

          expect(File.directory?("vendor/cache/alt_only_gem")).to be true
          expect(cached_gems).to include("rake-13.2.1")
        end
      end

      it "caches them by default, since Bundler 4 defaults cache_all to true" do
        with_alternate_path_gem do
          invoke_bundler("cache")

          expect(File.directory?("vendor/cache/alt_only_gem")).to be true
        end
      end

      it "doesn't cache them with BUNDLE_CACHE_ALL=false" do
        with_alternate_path_gem do
          invoke_bundler("cache", env: { "BUNDLE_CACHE_ALL" => "false" })

          expect(File.directory?("vendor/cache/alt_only_gem")).to be false
          expect(cached_gems).to include("rake-13.2.1")
        end
      end

      it "doesn't cache them with `bundle config --local cache_all false`" do
        with_alternate_path_gem do
          invoke_bundler("config set --local cache_all false")
          invoke_bundler("cache")

          expect(File.directory?("vendor/cache/alt_only_gem")).to be false
          expect(cached_gems).to include("rake-13.2.1")
        end
      end
    end
  end
end

# frozen_string_literal: true

describe Bundler::Multilock do
  describe "bundle clean" do
    def installed_gems
      Dir["#{local_gem_dir}/gems/*"].map { |path| File.basename(path) }.sort
    end

    def with_two_lockfiles(active: false)
      with_gemfile(<<~RUBY) do
        lockfile(active: #{!active}) do
          gem "rake", "13.2.1"
        end

        lockfile "Gemfile.alt.lock", active: #{active} do
          gem "rake", "13.1.0"
          gem "concurrent-ruby", "1.2.2"
        end
      RUBY
        use_local_bundle_path
        invoke_bundler("install")

        # a gem that isn't in either lockfile
        install_local_gem("rake", "13.0.6")
        expect(installed_gems).to include("rake-13.0.6")

        yield
      end
    end

    it "keeps the gems from every lockfile, including differing versions, and removes the rest" do
      with_two_lockfiles do
        invoke_bundler("clean")

        expect(installed_gems).to include("rake-13.2.1", "rake-13.1.0", "concurrent-ruby-1.2.2")
        expect(installed_gems).not_to include("rake-13.0.6")
      end
    end

    it "keeps the gems from every lockfile when an alternate lockfile is flagged as active" do
      with_two_lockfiles(active: true) do
        invoke_bundler("clean")

        expect(installed_gems).to include("rake-13.2.1", "rake-13.1.0", "concurrent-ruby-1.2.2")
        expect(installed_gems).not_to include("rake-13.0.6")
      end
    end

    it "reports what it would remove with --dry-run, without removing anything" do
      with_two_lockfiles do
        output = invoke_bundler("clean --dry-run")

        expect(output).to eq "Would have removed rake (13.0.6)\n"
        expect(installed_gems).to include("rake-13.0.6")
      end
    end

    it "keeps the gems from every lockfile when cleaning after `bundle install`" do
      with_two_lockfiles do
        invoke_bundler("config set --local clean true")
        invoke_bundler("install")

        expect(installed_gems).to include("rake-13.2.1", "rake-13.1.0", "concurrent-ruby-1.2.2")
        expect(installed_gems).not_to include("rake-13.0.6")
      end
    end

    it "only keeps the gems from the one lockfile when BUNDLE_LOCKFILE is specified" do
      with_two_lockfiles do
        invoke_bundler("clean", env: { "BUNDLE_LOCKFILE" => "Gemfile.alt.lock" })

        expect(installed_gems).to include("rake-13.1.0", "concurrent-ruby-1.2.2")
        expect(installed_gems).not_to include("rake-13.2.1", "rake-13.0.6")
      end
    end

    describe "with the `prune` setting for git metadata" do
      def with_git_gem_in_alternate_lockfile
        Dir.mktmpdir do |repo|
          Dir.chdir(repo) do
            create_local_gem("alt_git_gem", subdirectory: false)
            system("git init -q && git add -A && " \
                   "git -c user.name=test -c user.email=test@example.com commit -q -m init",
                   exception: true)
          end

          with_gemfile(<<~RUBY) do
            lockfile do
              gem "rake", "13.2.1"
            end

            lockfile "Gemfile.alt.lock" do
              gem "alt_git_gem", git: #{repo.inspect}
            end
          RUBY
            use_local_bundle_path
            invoke_bundler("install")

            yield
          end
        end
      end

      def git_metadata_dirs
        Dir.glob("#{local_gem_dir}/bundler/gems/*/.git", File::FNM_DOTMATCH)
      end

      it "removes the git metadata of git gems that only an alternate lockfile uses" do
        with_git_gem_in_alternate_lockfile do
          expect(git_metadata_dirs).not_to be_empty

          invoke_bundler("clean", env: { "BUNDLE_PRUNE" => "git" })

          expect(git_metadata_dirs).to be_empty
          expect(Dir["#{local_gem_dir}/bundler/gems/*"]).not_to be_empty
        end
      end

      it "leaves it alone when BUNDLE_LOCKFILE selects a lockfile without that git gem" do
        with_git_gem_in_alternate_lockfile do
          invoke_bundler("clean", env: { "BUNDLE_PRUNE" => "git", "BUNDLE_LOCKFILE" => "Gemfile.lock" })

          # it's removed as unused, instead
          expect(Dir["#{local_gem_dir}/bundler/gems/*"]).to be_empty
        end
      end
    end
  end
end

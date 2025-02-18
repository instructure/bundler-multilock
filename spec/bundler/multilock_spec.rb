# frozen_string_literal: true

require "tempfile"
require "open3"
require "fileutils"
require "shellwords"

describe "Bundler::Multilock" do
  it "generates a default Gemfile.lock when loaded, but not configured" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.2"
    RUBY
      invoke_bundler("install")
      output = invoke_bundler("info concurrent-ruby")

      expect(output).to include("1.2.2")
      expect(File.read("Gemfile.lock")).to include("1.2.2")
    end
  end

  it "injects plugin load commands into the Gemfile when installing" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_git = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --local_git=#{local_git}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        plugin "bundler-multilock", "~> #{Gem::Version.new(Bundler::Multilock::VERSION).segments[0..1].join(".")}"
        return unless Plugin.installed?("bundler-multilock")

        Plugin.send(:load_plugin, "bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "does not inject duplicate plugin load commands when you prefer single quotes" do
    gemfile = <<~RUBY
      # frozen_string_literal: true

      source 'https://rubygems.org'

      plugin 'bundler-multilock', '~> 1.2'
      return unless Plugin.installed?('bundler-multilock')

      Plugin.send(:load_plugin, 'bundler-multilock')

      gem 'concurrent-ruby', '1.2.2'
    RUBY

    with_gemfile("") do
      File.write("Gemfile", gemfile)

      local_git = Shellwords.escape(File.expand_path("../..", __dir__))
      invoke_bundler("plugin install bundler-multilock --local_git=#{local_git}")

      expect(File.read("Gemfile")).to eq gemfile
    end
  end

  it "does not inject when a secondary Gemfile has the necessary commands" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        eval_gemfile("injected.rb")
      RUBY

      File.write("injected.rb", <<~RUBY)
        plugin "bundler-multilock", "~> 1.2", path: #{File.expand_path("../..", __dir__).inspect}
        return unless Plugin.installed?("bundler-multilock")

        Plugin.send(:load_plugin, "bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY

      invoke_bundler("install")
      expect(File.read("Gemfile")).not_to include("bundler-multilock")
    end
  end

  it "disallows duplicate lockfiles" do
    with_gemfile(<<~RUBY) do
      lockfile()
      lockfile()
    RUBY
      expect { invoke_bundler("install") }.to raise_error(/is already defined/)
    end
  end

  it "disallows multiple active lockfiles" do
    with_gemfile(<<~RUBY) do
      lockfile(active: true)
      lockfile("full", active: true)
    RUBY
      expect { invoke_bundler("install") }.to raise_error(/can be flagged as active/)
    end
  end

  it "allows defaulting to an alternate lockfile" do
    with_gemfile(<<~RUBY) do
      lockfile(active: false)
      lockfile("full", active: true)
    RUBY
      invoke_bundler("install")
    end
  end

  it "disallows no lockfile set as active" do
    with_gemfile(<<~RUBY) do
      lockfile(active: false)
      lockfile("full")
    RUBY
      expect { invoke_bundler("install") }.to raise_error(/No lockfiles marked as active/)
    end
  end

  it "validates parent lockfile exists" do
    with_gemfile(<<~RUBY) do
      lockfile("full", parent: "missing")
    RUBY
      expect { invoke_bundler("install") }.to raise_error(/Parent lockfile .+missing\.lock is not defined/)
    end
  end

  it "allows externally defined parents if they exist" do
    with_gemfile(<<~RUBY) do
      lockfile("full", parent: Bundler.default_lockfile)
    RUBY
      invoke_bundler("install")
    end
  end

  it "generates custom lockfiles with varying versions" do
    with_gemfile(<<~RUBY) do
      lockfile do
        gem "concurrent-ruby", "1.1.10"
      end
      lockfile "new" do
        gem "concurrent-ruby", "1.2.2"
      end
    RUBY
      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).to include("1.1.10")
      expect(File.read("Gemfile.lock")).not_to include("1.2.2")
      expect(File.read("Gemfile.new.lock")).not_to include("1.1.10")
      expect(File.read("Gemfile.new.lock")).to include("1.2.2")
    end
  end

  it "handle _only_ custom variations" do
    with_gemfile(<<~RUBY) do
      gem "rake", "13.0.6"

      lockfile "variation1" do
        gem "concurrent-ruby", "1.1.10"
      end
      lockfile "variation2" do
        gem "concurrent-ruby", "1.2.2"
      end
    RUBY
      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).to include("rake")
      expect(File.read("Gemfile.lock")).not_to include("concurrent-ruby")

      output = invoke_bundler("list")
      expect(output).to include("rake")
      expect(output).not_to include("concurrent-ruby")

      output = invoke_bundler("info rake")
      expect(output).to include("13.0.6")
      output = invoke_bundler("info concurrent-ruby", allow_failure: true)
      expect(output).not_to include("1.1.10")

      expect(File.read("Gemfile.variation1.lock")).to include("concurrent-ruby")
      expect(File.read("Gemfile.variation1.lock")).to include("rake")
      expect(File.read("Gemfile.variation1.lock")).to include("1.1.10")
      expect(File.read("Gemfile.variation1.lock")).not_to include("1.2.2")
      expect(File.read("Gemfile.variation2.lock")).to include("concurrent-ruby")
      expect(File.read("Gemfile.variation2.lock")).to include("rake")
      expect(File.read("Gemfile.variation2.lock")).not_to include("1.1.10")
      expect(File.read("Gemfile.variation2.lock")).to include("1.2.2")
    end
  end

  it "bundle info, bundle list respect active" do
    with_gemfile(<<~RUBY) do
      gem "rake", "13.0.6"

      lockfile "variation1", active: true do
        gem "concurrent-ruby", "1.1.10"
      end
      lockfile "variation2" do
        gem "concurrent-ruby", "1.2.2"
      end
    RUBY
      invoke_bundler("install")

      output = invoke_bundler("list")
      expect(output).to include("rake")
      expect(output).to include("concurrent-ruby")

      output = invoke_bundler("info rake")
      expect(output).to include("13.0.6")
      output = invoke_bundler("info concurrent-ruby")
      expect(output).to include("1.1.10")
    end
  end

  it "generates lockfiles with a subset of gems" do
    with_gemfile(<<~RUBY) do
      lockfile "full" do
        gem "test_local", path: "test_local"
      end

      gem "concurrent-ruby", "1.2.2"
    RUBY
      create_local_gem("test_local")

      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).not_to include("test_local")
      expect(File.read("Gemfile.full.lock")).to include("test_local")

      expect(File.read("Gemfile.lock")).to include("concurrent-ruby")
      expect(File.read("Gemfile.full.lock")).to include("concurrent-ruby")
    end
  end

  it "fails if an additional lockfile contains an invalid gem" do
    with_gemfile(<<~RUBY) do
      lockfile("new")

      gem "concurrent-ruby", ">= 1.2.2"
    RUBY
      invoke_bundler("install")

      replace_lockfile_pin("Gemfile.lock", "concurrent-ruby", "1.2.2")
      replace_lockfile_pin("Gemfile.new.lock", "concurrent-ruby", "1.2.2")
      invoke_bundler("install")

      replace_lockfile_pin("Gemfile.new.lock", "concurrent-ruby", "1.2.3")
      invoke_bundler("install", env: { "BUNDLE_LOCKFILE" => "new" })

      expect { invoke_bundler("check") }.to raise_error(/concurrent-ruby.*does not match/m)
    end
  end

  it "preserves the locked version of a gem in an alternate lockfile when updating a different gem in common" do
    with_gemfile(<<~RUBY) do
      lockfile("full", active: true) do
        gem "net-smtp", "0.3.2"
      end

      gem "net-ldap", "0.17.0"
    RUBY
      invoke_bundler("install")

      expect(invoke_bundler("info net-ldap")).to include("0.17.0")
      expect(invoke_bundler("info net-smtp")).to include("0.3.2")

      # loosen the requirement on both gems
      write_gemfile(<<~RUBY)
        lockfile("full", active: true) do
          gem "net-smtp", "~> 0.3"
        end

        gem "net-ldap", "~> 0.17"
      RUBY

      # but only update net-ldap
      invoke_bundler("update net-ldap")

      # net-smtp should be untouched, even though it's no longer pinned
      expect(invoke_bundler("info net-ldap")).not_to include("0.17.0")
      expect(invoke_bundler("info net-smtp")).to include("0.3.2")
    end
  end

  it "maintains consistency across multiple Gemfiles" do
    with_gemfile(<<~RUBY) do
      lockfile("local_test/Gemfile.lock",
               gemfile: "local_test/Gemfile")

      gem "net-smtp", "0.3.2"
    RUBY
      create_local_gem("local_test", <<~RUBY)
        spec.add_dependency "net-smtp", "~> 0.3"
      RUBY

      invoke_bundler("install")

      # locks to 0.3.2 in the local gem's lockfile, even though the local
      # gem itself would allow newer
      expect(File.read("local_test/Gemfile.lock")).to include("0.3.2")
    end
  end

  it "maintains consistency across local gem's lockfiless when one is included in the other" do
    with_gemfile(<<~RUBY) do
      lockfile("local_test/Gemfile.lock",
               gemfile: "local_test/Gemfile")

      gem "local_test", path: "local_test"
      gem "net-smtp", "0.3.2"
    RUBY
      create_local_gem("local_test", <<~RUBY)
        spec.add_dependency "net-smtp", "~> 0.3"
      RUBY

      invoke_bundler("install")

      replace_lockfile_pin("local_test/Gemfile.lock", "net-smtp", "0.3.3")

      # write_gemfile(<<~RUBY)
      #   lockfile("local_test/Gemfile.lock",
      #          gemfile: "local_test/Gemfile")

      #   gem "net-smtp", "~> 0.3.2"
      # RUBY

      invoke_bundler("install")
      expect(File.read("local_test/Gemfile.lock")).to include("0.3.2")
    end
  end

  it "syncs from a parent lockfile" do
    with_gemfile(<<~RUBY) do
      lockfile do
        gem "activesupport", "~> 6.1.0"
      end

      lockfile("6.0") do
        gem "activesupport", "~> 6.0.0"
      end

      lockfile("6.0-alt", parent: "6.0") do
        gem "activesupport", "> 5.2", "< 7.2"
      end
    RUBY
      invoke_bundler("install")

      default = invoke_bundler("info activesupport")
      six_oh = invoke_bundler("info activesupport 2> /dev/null", env: { "BUNDLE_LOCKFILE" => "6.0" })
      alt = invoke_bundler("info activesupport 2> /dev/null", env: { "BUNDLE_LOCKFILE" => "6.0-alt" })

      expect(default).to include("6.1")
      expect(default).not_to eq six_oh
      expect(six_oh).to include("6.0")
      # alt is the same as 6.0, even though it should allow 6.1
      expect(alt).to eq six_oh
    end
  end

  it "whines about non-pinned dependencies in flagged gemfiles" do
    with_gemfile(<<~RUBY) do
      lockfile("full", enforce_pinned_additional_dependencies: true) do
        gem "net-smtp", "~> 0.3"
      end

      gem "net-ldap", "0.17.0"
    RUBY
      expect do
        invoke_bundler("install")
      end.to raise_error(/net-smtp \([0-9.]+\) in Gemfile.full.lock has not been pinned/m)

      # not only have to pin net-smtp, but also its transitive dependencies
      write_gemfile(<<~RUBY)
        lockfile("full", enforce_pinned_additional_dependencies: true) do
          gem "net-smtp", "0.3.2"
            gem "net-protocol", "0.2.1"
            gem "timeout", "0.3.2"
        end

        gem "net-ldap", "0.17.0"
      RUBY

      invoke_bundler("install") # no error, because it's now pinned
    end
  end

  context "with mismatched dependencies disallowed" do
    it "notifies about mismatched versions between different lockfiles" do
      with_gemfile(<<~RUBY) do
        lockfile do
          gem "activesupport", ">= 6.0", "< 7.0"
        end

        lockfile("full") do
          gem "activesupport", "6.0.6.1"
        end
      RUBY
        expect do
          invoke_bundler("install")
        end.to raise_error(Regexp.new("activesupport \\(6.0.6.1\\) in Gemfile.full.lock " \
                                      "does not match the parent lockfile's version"))
      end
    end

    it "notifies about mismatched versions between different lockfiles for sub-dependencies" do
      with_gemfile(<<~RUBY) do
        gem "activesupport", "6.1.7.6" # depends on tzinfo ~> 2.0, so will get >= 2.0.6

        lockfile("full") do
          gem "tzinfo", "2.0.5"
        end

      RUBY
        expect do
          invoke_bundler("install")
        end.to raise_error(/tzinfo \(2.0.5\) in Gemfile.full.lock does not match the parent lockfile's version/)
      end
    end
  end

  it "allows mismatched explicit dependencies by default" do
    with_gemfile(<<~RUBY) do
      lockfile do
        gem "activesupport", "~> 6.0.0"
      end

      lockfile("new") do
        gem "activesupport", "6.1.7.6"
      end
    RUBY
      invoke_bundler("install") # no error
      expect(File.read("Gemfile.lock")).to include("6.0.")
      expect(File.read("Gemfile.lock")).not_to include("6.1.7.6")
      expect(File.read("Gemfile.new.lock")).not_to include("6.0.")
      expect(File.read("Gemfile.new.lock")).to include("6.1.7.6")
    end
  end

  it "disallows mismatched implicit dependencies" do
    with_gemfile(<<~RUBY) do
      lockfile("local_test/Gemfile.lock",
               gemfile: "local_test/Gemfile")

      gem "snaky_hash", "2.0.1"
    RUBY
      create_local_gem("local_test", <<~RUBY)
        spec.add_dependency "zendesk_api", "1.28.0"
      RUBY

      expect do
        invoke_bundler("install")
      end.to raise_error(Regexp.new("hashie \\(4[0-9.]+\\) in local_test/Gemfile.lock " \
                                    "does not match the parent lockfile's version \\(@([0-9.]+)\\)"))
    end
  end

  it "removes transitive deps from secondary lockfiles when they disappear from the primary lockfile" do
    with_gemfile(<<~RUBY) do
      lockfile("full")

      gem "pact-mock_service", "3.11.0"
    RUBY
      # get 3.11.0 intalled
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        lockfile("full")

        gem "pact-mock_service", "~> 3.11.0"
      RUBY

      # update the lockfiles with the looser dependency (but with 3.11.0)
      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).to include("filelock")
      full_lock = File.read("Gemfile.full.lock")
      expect(full_lock).to include("filelock")

      # update the default lockfile to 3.11.2
      invoke_bundler("update")

      # but revert the full lockfile, and re-sync it
      # as part of a regular bundle install
      File.write("Gemfile.full.lock", full_lock)

      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).not_to include("filelock")
      expect(File.read("Gemfile.full.lock")).not_to include("filelock")
    end
  end

  it "updates the lockfile when restrictions are loosened (in the alternate lockfile)" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("full", active: true) do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        lockfile("full", active: true) do
          gem "concurrent-ruby", "~> 1.2.0"
        end
      RUBY

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).to include("~> 1.2.0")
    end
  end

  it "updates the lockfile when restrictions are loosened" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.1"

      lockfile("full", active: true) do
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "concurrent-ruby", "~> 1.2.0"

        lockfile("full", active: true) do
        end
      RUBY

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).to include("~> 1.2.0")
    end
  end

  it "updates the lockfile when a gem updates, and the alternate lockfile " \
     "has the exact same set of gems as the default lockfile" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.1"

      lockfile("full", active: true) do
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "concurrent-ruby", "~> 1.2.0"

        lockfile("full", active: true) do
        end
      RUBY

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).to include("1.2.1")

      replace_lockfile_pin("Gemfile.lock", "concurrent-ruby", "1.2.2")

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).to include("1.2.2")
    end
  end

  it "updates the lockfile when only the platforms differ" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("full")
    RUBY
      invoke_bundler("install")

      invoke_bundler("lock --add-platform unknown")

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).to include("unknown")

      invoke_bundler("lock --remove-platform unknown")

      invoke_bundler("install")
      expect(File.read("Gemfile.full.lock")).not_to include("unknown")
    end
  end

  it "installs missing gems in secondary lockfile" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile do
        gem "concurrent-ruby", "1.2.2"
      end

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")
      Bundler.with_unbundled_env do
        `gem uninstall concurrent-ruby -v 1.2.1 2> #{File::NULL}`
      end
      invoke_bundler("install")
      invoke_bundler("info concurrent-ruby", env: { "BUNDLE_LOCKFILE" => "alt1" })
    end
  end

  it "doesn't break outdated" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")
      invoke_bundler("outdated")
    end
  end

  it "doesn't break env" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")
      invoke_bundler("env")
    end
  end

  it "errors if you specify a non-existent lockfile" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")
      expect { invoke_bundler("exec rake -v", env: { "BUNDLE_LOCKFILE" => "alt2" }) }
        .to raise_error(/Could not locate lockfile "alt2"/)

      invoke_bundler("binstub rake")
      Bundler.with_unbundled_env do
        ENV["BUNDLE_LOCKFILE"] = "alt2"
        expect(`bin/rake -v 2>&1`).to match(/Could not locate lockfile "alt2"/)
      ensure
        ENV.delete("BUNDLE_LOCKFILE")
      end
    end
  end

  it "allows explicitly specifying the active lockfile" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install", env: { "BUNDLE_LOCKFILE" => "Gemfile.lock" })
    end
  end

  # so that it won't downgrade if that's all you have available
  it "installs missing deps from alternate lockfiles before syncing" do
    Bundler.with_unbundled_env do
      `gem uninstall activemodel -a --force 2> #{File::NULL}`
      `gem install activemodel -s https://rubygems.org -v 6.1.7.6`
    end

    with_gemfile(<<~RUBY) do
      lockfile do
        gem "activemodel", ">= 6.0"
      end

      lockfile("rails-6.1") do
        gem "activemodel", "~> 6.1.0"
      end
    RUBY
      invoke_bundler("install --local")
      expect(invoke_bundler("info activesupport", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("6.1.7.6")

      Bundler.with_unbundled_env do
        `gem uninstall activemodel -v 6.1.7.6 --force 2> #{File::NULL}`
        `gem install activemodel -s https://rubygems.org -v 6.1.6`
      end

      expect { invoke_bundler("check") }.to raise_error(/The following gems are missing/)
      invoke_bundler("install")

      # it should have re-installed 6.1.7.6, leaving the lockfile alone
      expect(invoke_bundler("info activemodel", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("6.1.7.6")
    end
  end

  it "updates bundler version in secondary lockfiles" do
    with_gemfile(<<~RUBY) do
      gem "rake"

      lockfile("alt1") do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")

      update_lockfile_bundler("Gemfile.alt1.lock", "2.4.18")

      invoke_bundler("install")

      expect(File.read("Gemfile.alt1.lock")).not_to include("2.4.18")
      expect(File.read("Gemfile.alt1.lock")).to include(Bundler::VERSION)
    end
  end

  it "only syncs once per lockfile" do
    with_gemfile(<<~RUBY) do
      gemspec

      lockfile("rails-6.1", active: true) do
        gem "activesupport", "~> 6.1.0"
      end
    RUBY
      create_local_gem("test", subdirectory: false)
      invoke_bundler("install")
      output = invoke_bundler("install", env: { "DEBUG" => "1" })

      expect(output.split("\n").grep(/Syncing to alternate lockfiles/).length).to be 1
    end
  end

  it "does not re-sync lockfiles that have conflicting sub-dependencies" do
    with_gemfile(<<~RUBY) do
      lockfile do
        gem "activemodel", "~> 6.1.0"
      end

      lockfile("rails-6.0") do
        gem "activemodel", "~> 6.0.0"
      end
    RUBY
      output = invoke_bundler("install")
      expect(output).to include("Syncing")

      output = invoke_bundler("install")
      expect(output).not_to include("Syncing")
    end
  end

  it "removes now-missing explicit dependencies from secondary lockfiles" do
    with_gemfile(<<~RUBY) do
      gem "inst-jobs", "3.1.6"
      gem "activerecord-pg-extensions"

      lockfile("alt") {}
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "inst-jobs", "3.1.6"

        lockfile("alt") {}
      RUBY

      invoke_bundler("install")
      expect(File.read("Gemfile.lock")).to eq File.read("Gemfile.alt.lock")
    end
  end

  it "does not evaluate the default lockfile at all if an alternate is active, " \
     "without specifying that lockfile explicitly" do
    with_gemfile(<<~RUBY) do
      gem "inst-jobs", "3.1.6"

      lockfile active: ENV["ALTERNATE"] != "1" do
        raise "evaluated!" if ENV["ALTERNATE"] == "1"
      end

      lockfile "alt", active: ENV["ALTERNATE"] == "1" do
        gem "activerecord-pg-extensions"
      end
    RUBY
      invoke_bundler("install")

      invoke_bundler("install", env: { "ALTERNATE" => "1", "BUNDLE_LOCKFILE" => "active" })
    end
  end

  it "doesn't update versions in alternate lockfiles when syncing" do
    # first
    with_gemfile(<<~RUBY) do
      gem "rubocop", "1.45.0"

      lockfile do
        gem "activesupport", "6.0.0"
      end

      lockfile "rails-6.1" do
        gem "activesupport", "6.1.0"
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "rubocop", "~> 1.45.0"

        lockfile do
          gem "activesupport", "~> 6.0.0"
        end

        lockfile "rails-6.1" do
          gem "activesupport", "~> 6.1.0"
        end
      RUBY

      # first, unpin, but ensure no gems update during this process
      invoke_bundler("install")

      expect(invoke_bundler("info rubocop")).to include("1.45.0")
      expect(invoke_bundler("info activesupport")).to include("6.0.0")
      expect(invoke_bundler("info rubocop", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("1.45.0")
      expect(invoke_bundler("info activesupport", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("6.1.0")

      # now, update an unrelated gem, but _only_ that gem
      # this should not update other gems in the alternate lockfiles
      invoke_bundler("update rubocop --conservative")

      expect(invoke_bundler("info rubocop")).to include("1.45.1")
      expect(invoke_bundler("info activesupport")).to include("6.0.0")
      expect(invoke_bundler("info rubocop", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("1.45.1")
      expect(invoke_bundler("info activesupport", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("6.1.0")
    end
  end

  it "keeps transitive dependencies in sync, even when the intermediate deps are conflicting" do
    orig_gemfile = <<~RUBY
      gem 'datadog', '~> 2.0'

      lockfile do
        gem "activesupport", "6.0.0"
      end

      lockfile "rails-6.1" do
        gem "activesupport", "6.1.0"
      end
    RUBY

    with_gemfile("") do
      # install once with nothing so that it doesn't try to lock every single
      # platform available for FFI
      invoke_bundler("install")

      write_gemfile(orig_gemfile)
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem 'datadog', '~> 2.10.0'

        lockfile do
          gem "activesupport", "~> 6.0.0"
        end

        lockfile "rails-6.1" do
          gem "activesupport", "~> 6.1.0"
        end
      RUBY

      FileUtils.cp("Gemfile.rails-6.1.lock", "Gemfile.rails-6.1.lock.orig")
      # roll back to ddtrace 1.20.0
      invoke_bundler("install")

      # loosen the requirement to allow > 1.20, but with it locked to
      # 1.12. But act like the alternate lockfile didn't get updated
      write_gemfile(orig_gemfile)
      FileUtils.cp("Gemfile.rails-6.1.lock.orig", "Gemfile.rails-6.1.lock")

      # now a plain install should sync the alternate lockfile, rolling it back too
      invoke_bundler("install")

      expect(invoke_bundler("info datadog")).to include("2.10.0")
      expect(invoke_bundler("info datadog", env: { "BUNDLE_LOCKFILE" => "rails-6.1" })).to include("2.10.0")
    end
  end

  it "syncs gems whose platforms changed slightly" do
    if RUBY_VERSION < "3.0"
      skip "The test case that triggers this requires Ruby 3.0+; " \
           "just rely on this test running on other ruby versions"
    end

    with_gemfile(<<~RUBY) do
      gem "sqlite3", "~> 1.7"

      lockfile("all") {}
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "sqlite3"

        lockfile("all") {}
      RUBY
      invoke_bundler("install")

      expect(invoke_bundler("info sqlite3")).to include("1.7.3")
      expect(invoke_bundler("info sqlite3", env: { "BUNDLE_LOCKFILE" => "all" })).to include("1.7.3")

      invoke_bundler("update sqlite3")
      expect(invoke_bundler("info sqlite3")).not_to include("1.7.3")
      expect(invoke_bundler("info sqlite3", env: { "BUNDLE_LOCKFILE" => "all" })).not_to include("1.7.3")
    end
  end

  it "syncs ruby version" do
    with_gemfile(<<~RUBY) do
      gem "concurrent-ruby", "1.2.2"

      lockfile do
        ruby ">= 2.1"
      end

      lockfile "alt" do
      end
    RUBY
      invoke_bundler("install")

      expect(File.read("Gemfile.lock")).to include(Bundler::RubyVersion.system.to_s)
      expect(File.read("Gemfile.alt.lock")).to include(Bundler::RubyVersion.system.to_s)

      update_lockfile_ruby("Gemfile.alt.lock", "ruby 2.1.0p0")

      expect do
        invoke_bundler("check")
      end.to raise_error(/ruby \(ruby 2.1.0p0\) in Gemfile.alt.lock does not match the parent lockfile's version/)

      update_lockfile_ruby("Gemfile.alt.lock", nil)
      expect do
        invoke_bundler("check")
      end.to raise_error(/ruby \(<none>\) in Gemfile.alt.lock does not match the parent lockfile's version/)

      invoke_bundler("install")
      expect(File.read("Gemfile.alt.lock")).to include(Bundler::RubyVersion.system.to_s)

      update_lockfile_ruby("Gemfile.lock", "ruby 2.6.0p0")
      update_lockfile_ruby("Gemfile.alt.lock", nil)

      invoke_bundler("install")
      expect(File.read("Gemfile.alt.lock")).to include("ruby 2.6.0p0")
    end
  end

  it "ignores installation errors when an alternate lockfile specifies a gem " \
     "version incompatible with the current ruby" do
    with_gemfile(<<~RUBY) do
      gem "nokogiri"

      lockfile do
      end

      lockfile "alt" do
      end
    RUBY
      invoke_bundler("install")

      incompatible_nokogiri_version = case RUBY_VERSION
                                      when ("3.3"..)
                                        "1.15.6"
                                      when ("3.0"..)
                                        skip "There isn't a recent nokogiri version incompatible " \
                                             "with this version of ruby; just rely on this test " \
                                             "running on other ruby versions"
                                      else
                                        "1.16.0"
                                      end

      replace_lockfile_pin("Gemfile.lock", "nokogiri", incompatible_nokogiri_version)
      replace_lockfile_pin("Gemfile.alt.lock", "nokogiri", incompatible_nokogiri_version)

      expect { invoke_bundler("check") }.to raise_error(/The following gems are missing/)

      invoke_bundler("install")
    end
  end

  it "doesn't error when no lockfiles are defined but ruby version is set" do
    with_gemfile(<<~RUBY) do
      gem "nokogiri"

      ruby ">= 2.1"
    RUBY
      invoke_bundler("install")
    end
  end

  it "syncs git sources that have updated" do
    with_gemfile(<<~RUBY) do
      gem "rspecq", github: "instructure/rspecq"

      lockfile "alt" do
      end
    RUBY
      invoke_bundler("install")
      replace_lockfile_git_pin("d7fa5536da01cccb5109ba05c9e236d6660da593")
      invoke_bundler("install")

      expect(invoke_bundler("info rspecq")).to include("d7fa553")

      invoke_bundler("update rspecq")
      expect(invoke_bundler("info rspecq")).not_to include("d7fa553")
    end
  end

  private

  def create_local_gem(name, content = "", subdirectory: true)
    if subdirectory
      FileUtils.mkdir_p(name)
      subdirectory = "#{name}/"
    else
      subdirectory = nil
    end
    File.write("#{subdirectory}#{name}.gemspec", <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name          = #{name.inspect}
        spec.version       = "0.0.1"
        spec.authors       = ["Instructure"]
        spec.summary       = "for testing only"

        #{content}
      end
    RUBY

    return unless subdirectory

    File.write("#{name}/Gemfile", <<~RUBY)
      source "https://rubygems.org"

      gemspec
    RUBY
  end

  # creates a new temporary directory, writes the gemfile to it, and yields
  #
  # @param (see #write_gemfile)
  # @yield
  def with_gemfile(content = nil)
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        write_gemfile(content)

        invoke_bundler("config frozen false")

        yield
      end
    end
  end

  # @param content [String]
  #   Ruby code to set up lockfiles by calling `lockfile`.
  def write_gemfile(content)
    raise ArgumentError, "Did you mean to use `with_gemfile`?" if block_given?

    File.write("Gemfile", <<~RUBY)
      source "https://rubygems.org"

      plugin "bundler-multilock", "~> 1.2", path: #{File.expand_path("../..", __dir__).inspect}
      return unless Plugin.installed?("bundler-multilock")

      Plugin.send(:load_plugin, "bundler-multilock")

      #{content}
    RUBY
  end

  # Shells out to a new instance of bundler, with a clean bundler env
  #
  # @param subcommand [String] Args to pass to bundler
  # @raise [RuntimeError] if the bundle command fails
  def invoke_bundler(subcommand, env: {}, allow_failure: false)
    output = nil
    bundler_version = ENV.fetch("BUNDLER_VERSION")
    bin = begin
      Gem.bin_path("bundler", "bundler", bundler_version)
    rescue Gem::Exception
      "bundler"
    end
    command = "#{bin} #{subcommand}"
    Bundler.with_unbundled_env do
      output, status = Open3.capture2e(env, command)

      raise "bundle #{subcommand} failed: #{output}" unless allow_failure || status.success?
    end
    output
  end

  # Directly modifies a lockfile to adjust the version of a gem
  #
  # Useful for simulating certain unusual situations that can arise.
  #
  # @param lockfile [String] The lockfile's location
  # @param gem [String] The gem's name
  # @param version [String] The new version to "pin" the gem to
  def replace_lockfile_pin(lockfile, gem, version)
    new_contents = File.read(lockfile).gsub(%r{#{gem} \([0-9a-z.]+((?:-[a-z0-9_]+)*)\)}, "#{gem} (#{version}\\1)")

    File.write(lockfile, new_contents)
  end

  def replace_lockfile_git_pin(revision)
    new_contents = File.read("Gemfile.lock").gsub(/revision: [0-9a-f]+/, "revision: #{revision}")

    File.write("Gemfile.lock", new_contents)
  end

  def update_lockfile_bundler(lockfile, version)
    new_contents = File.read(lockfile).gsub(/BUNDLED WITH\n   [0-9.]+/, "BUNDLED WITH\n  #{version}")

    File.write(lockfile, new_contents)
  end

  def update_lockfile_ruby(lockfile, version)
    old_contents = File.read(lockfile)
    new_version = version ? "RUBY VERSION\n   #{version}\n\n" : ""
    new_contents = old_contents.gsub(/RUBY VERSION\n   #{Bundler::RubyVersion::PATTERN}\n\n/o, new_version)

    File.write(lockfile, new_contents)
  end
end

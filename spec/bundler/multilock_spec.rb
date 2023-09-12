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

        plugin "bundler-multilock", "~> 1.0"
        return unless Plugin.installed?("bundler-multilock")

        Plugin.send(:load_plugin, "bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
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

  it "disallows multiple default lockfiles" do
    with_gemfile(<<~RUBY) do
      lockfile(default: true)
      lockfile("full", default: true)
    RUBY
      expect { invoke_bundler("install") }.to raise_error(/can be flagged as the default/)
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

  it "bundle info, bundle list respect default" do
    with_gemfile(<<~RUBY) do
      gem "rake", "13.0.6"

      lockfile "variation1", default: true do
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
      create_local_gem("test_local", "")

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

      replace_lockfile_pin("Gemfile.new.lock", "concurrent-ruby", "9.9.9")

      expect { invoke_bundler("check") }.to raise_error(/concurrent-ruby.*does not match/m)
    end
  end

  it "preserves the locked version of a gem in an alternate lockfile when updating a different gem in common" do
    with_gemfile(<<~RUBY) do
      lockfile("full", default: true) do
        gem "net-smtp", "0.3.2"
      end

      gem "net-ldap", "0.17.0"
    RUBY
      invoke_bundler("install")

      expect(invoke_bundler("info net-ldap")).to include("0.17.0")
      expect(invoke_bundler("info net-smtp")).to include("0.3.2")

      # loosen the requirement on both gems
      write_gemfile(<<~RUBY)
        lockfile("full", default: true) do
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

  it "whines about non-pinned dependencies in flagged gemfiles" do
    with_gemfile(<<~RUBY) do
      lockfile("full", enforce_pinned_additional_dependencies: true) do
        gem "net-smtp", "~> 0.3"
      end

      gem "net-ldap", "0.17.0"
    RUBY
      expect do
        invoke_bundler("install")
      end.to raise_error(/net-smtp \([0-9.]+\) in Gemfile.full.lock has not been pinned/)

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
          gem "activesupport", "~> 6.1.0"
        end

        lockfile("full", allow_mismatched_dependencies: false) do
          gem "activesupport", "7.0.4.3"
        end
      RUBY
        expect do
          invoke_bundler("install")
        end.to raise_error(Regexp.new("activesupport \\(7.0.4.3\\) in Gemfile.full.lock " \
                                      "does not match the default lockfile's version"))
      end
    end

    it "notifies about mismatched versions between different lockfiles for sub-dependencies" do
      with_gemfile(<<~RUBY) do
        gem "activesupport", "7.0.4.3" # depends on tzinfo ~> 2.0, so will get >= 2.0.6

        lockfile("full", allow_mismatched_dependencies: false) do
          gem "tzinfo", "2.0.5"
        end

      RUBY
        expect do
          invoke_bundler("install")
        end.to raise_error(/tzinfo \(2.0.5\) in Gemfile.full.lock does not match the default lockfile's version/)
      end
    end
  end

  it "allows mismatched explicit dependencies by default" do
    with_gemfile(<<~RUBY) do
      lockfile do
        gem "activesupport", "~> 6.1.0"
      end

      lockfile("new") do
        gem "activesupport", "7.0.4.3"
      end
    RUBY
      invoke_bundler("install") # no error
      expect(File.read("Gemfile.lock")).to include("6.1.")
      expect(File.read("Gemfile.lock")).not_to include("7.0.4.3")
      expect(File.read("Gemfile.new.lock")).not_to include("6.1.")
      expect(File.read("Gemfile.new.lock")).to include("7.0.4.3")
    end
  end

  it "disallows mismatched implicit dependencies" do
    with_gemfile(<<~RUBY) do
      lockfile("local_test/Gemfile.lock",
               allow_mismatched_dependencies: false,
               gemfile: "local_test/Gemfile")

      gem "snaky_hash", "2.0.1"
    RUBY
      create_local_gem("local_test", <<~RUBY)
        spec.add_dependency "zendesk_api", "1.28.0"
      RUBY

      expect do
        invoke_bundler("install")
      end.to raise_error(Regexp.new("hashie \\(4[0-9.]+\\) in local_test/Gemfile.lock " \
                                    "does not match the default lockfile's version \\(@([0-9.]+)\\)"))
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

      lockfile("full", default: true) do
        gem "concurrent-ruby", "1.2.1"
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        lockfile("full", default: true) do
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

      lockfile("full", default: true) do
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "concurrent-ruby", "~> 1.2.0"

        lockfile("full", default: true) do
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

      lockfile("full", default: true) do
      end
    RUBY
      invoke_bundler("install")

      write_gemfile(<<~RUBY)
        gem "concurrent-ruby", "~> 1.2.0"

        lockfile("full", default: true) do
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

  private

  def create_local_gem(name, content)
    FileUtils.mkdir_p(name)
    File.write("#{name}/#{name}.gemspec", <<~RUBY)
      Gem::Specification.new do |spec|
        spec.name          = #{name.inspect}
        spec.version       = "0.0.1"
        spec.authors       = ["Instructure"]
        spec.summary       = "for testing only"

        #{content}
      end
    RUBY

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

      plugin "bundler-multilock", "~> 1.0", path: #{File.expand_path("../..", __dir__).inspect}
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
    new_contents = File.read(lockfile).gsub(%r{#{gem} \([0-9.]+\)}, "#{gem} (#{version})")

    File.write(lockfile, new_contents)
  end
end

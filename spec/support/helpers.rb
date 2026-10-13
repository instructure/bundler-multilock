# frozen_string_literal: true

require "fileutils"
require "open3"
require "shellwords"
require "tempfile"

# Helpers for specs, which run bundler against temporary Gemfiles
module MultilockHelpers
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

      plugin "bundler-multilock", "#{plugin_requirement}", path: #{plugin_path.inspect}
      return unless Plugin.loaded?("bundler-multilock")

      #{content}
    RUBY
  end

  # Shells out to a new instance of bundler, with a clean bundler env
  #
  # @param subcommand [String] Args to pass to bundler
  # @raise [RuntimeError] if the bundle command fails
  def invoke_bundler(subcommand, env: {}, allow_failure: false, timeout: nil)
    output = nil
    command = "#{bundler_bin} #{subcommand}"
    Bundler.with_unbundled_env do
      # in its own process group, so that it can be killed along with any children
      Open3.popen2e(env, command, pgroup: true) do |stdin, stdout_and_stderr, wait_thread|
        stdin.close
        reader = Thread.new { stdout_and_stderr.read }

        unless wait_thread.join(timeout)
          Process.kill("KILL", -wait_thread.pid)
          wait_thread.join
          raise "bundle #{subcommand} timed out after #{timeout} seconds: #{reader.value}"
        end

        output = reader.value
        raise "bundle #{subcommand} failed: #{output}" unless allow_failure || wait_thread.value.success?
      end
    end
    output
  end

  # @return [String] the bundler executable for the bundler version under test
  def bundler_bin
    Gem.bin_path("bundler", "bundler", ENV.fetch("BUNDLER_VERSION"))
  rescue Gem::Exception
    "bundler"
  end

  # The version requirement the plugin injects into (and expects in) Gemfiles
  def plugin_requirement
    Bundler::Multilock::Preamble.requirement
  end

  # @return [String] the path to this plugin, for installing it in specs
  def plugin_path
    File.expand_path("../..", __dir__)
  end

  # Shells out to `gem`, with a clean bundler env
  #
  # @param subcommand [String] Args to pass to gem
  # @raise [RuntimeError] if the gem command fails
  def invoke_gem(subcommand)
    output = nil
    Bundler.with_unbundled_env do
      output, status = Open3.capture2e("gem #{subcommand}")

      raise "gem #{subcommand} failed: #{output}" unless status.success?
    end
    output
  end

  # Installs gems into the current directory instead of the system, so that a spec
  # neither depends on nor changes which gems are installed globally
  def use_local_bundle_path
    invoke_bundler("config set --local path vendor/bundle")
  end

  # The directory gems are installed into after calling {#use_local_bundle_path}
  def local_gem_dir
    "vendor/bundle/#{Bundler.ruby_scope}"
  end

  # Installs a gem (and its dependencies) into {#local_gem_dir}
  def install_local_gem(name, version)
    invoke_gem("install #{name} -v #{version} -s https://rubygems.org --install-dir #{local_gem_dir} --no-document")
  end

  # Uninstalls a gem from {#local_gem_dir}, even if other gems depend on it
  def uninstall_local_gem(name, version)
    invoke_gem("uninstall #{name} -v #{version} --force --install-dir #{local_gem_dir}")
  end

  # Directly modifies a lockfile to adjust the version of a gem
  #
  # Useful for simulating certain unusual situations that can arise.
  #
  # @param lockfile [String] The lockfile's location
  # @param gem [String] The gem's name
  # @param version [String] The new version to "pin" the gem to
  def replace_lockfile_pin(lockfile, gem, version)
    new_contents = File.read(lockfile).gsub(/(?<![\w-])#{gem} \([0-9a-z.]+((?:-[a-z0-9_]+)*)\)/,
                                            "#{gem} (#{version}\\1)")

    File.write(lockfile, remove_checksum(new_contents, gem))
  end

  # The checksum is no longer valid after manually changing the version
  def remove_checksum(contents, gem)
    contents.gsub(/^(  #{Regexp.escape(gem)} \([^)]+\)) sha256=\h+$/, "\\1")
  end

  # @return [Hash<String, String>] the CHECKSUMS entries of a lockfile, keyed by gem and version
  def lockfile_checksums(lockfile)
    section = File.read(lockfile)[/^CHECKSUMS\n(.*?)\n\n/m, 1]
    raise "#{lockfile} doesn't have checksums" unless section

    section.lines.to_h do |line|
      full_name, checksum = line.strip.split(" sha256=")
      [full_name, checksum]
    end
  end

  # Expects every gem (and version) locked in both lockfiles to have the same checksum in each
  #
  # @return [Array<String>] the gems (and versions) in common
  def expect_matching_checksums(lockfile1, lockfile2)
    checksums1 = lockfile_checksums(lockfile1)
    checksums2 = lockfile_checksums(lockfile2)
    common = checksums1.keys & checksums2.keys

    expect(checksums2.slice(*common)).to eq checksums1.slice(*common)
    common
  end

  def remove_checksums_section(lockfile)
    File.write(lockfile, File.read(lockfile).sub(/^CHECKSUMS\n.*?\n\n/m, ""))
  end

  def replace_lockfile_git_pin(revision)
    new_contents = File.read("Gemfile.lock").gsub(/revision: [0-9a-f]+/, "revision: #{revision}")

    File.write("Gemfile.lock", new_contents)
  end

  def replace_string(lockfile, old_string, new_string)
    new_contents = File.read(lockfile).gsub(old_string, new_string)

    File.write(lockfile, new_contents)
  end

  def update_lockfile_bundler(lockfile, version)
    new_contents = File.read(lockfile).gsub(/BUNDLED WITH\n +[0-9a-z.]+/, "BUNDLED WITH\n  #{version}")

    File.write(lockfile, new_contents)
  end

  def update_lockfile_ruby(lockfile, version)
    old_contents = File.read(lockfile)
    new_version = version ? "RUBY VERSION\n  #{version}\n\n" : ""
    new_contents = old_contents.gsub(/RUBY VERSION\n +#{Bundler::RubyVersion::PATTERN}\n\n/o, new_version)

    File.write(lockfile, new_contents)
  end
end

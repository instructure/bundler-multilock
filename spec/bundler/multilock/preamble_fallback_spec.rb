# frozen_string_literal: true

describe Bundler::Multilock::Preamble do
  context "when the Gemfile is evaluated without the plugin loaded" do
    # Installs both lockfiles with the plugin, then yields an environment whose app
    # config has no plugin index, as in a fresh checkout of an image whose gems
    # were installed at build time
    def with_checkout_without_plugin_index
      with_gemfile("") do
        File.write("Gemfile", <<~RUBY)
          source "https://rubygems.org"

          plugin "bundler-multilock", "#{plugin_requirement}", path: #{plugin_path.inspect}
          #{plugin_fallback}
          lockfile do
            gem "concurrent-ruby", "1.1.10"
          end
          lockfile "Gemfile.new.lock" do
            gem "concurrent-ruby", "1.2.2"
          end
        RUBY
        use_local_bundle_path
        invoke_bundler("install")

        FileUtils.cp_r(".bundle", "without_index")
        FileUtils.rm_rf("without_index/plugin")
        yield({ "BUNDLE_APP_CONFIG" => File.expand_path("without_index") })
      end
    end

    def concurrent_ruby_version(env)
      invoke_bundler(%(exec ruby -e 'puts Gem.loaded_specs["concurrent-ruby"].version'), env:).lines.last.strip
    end

    it "keeps the fallback instead of injecting another guard" do
      with_checkout_without_plugin_index do
        expect(File.read("Gemfile").scan("Plugin.loaded?").length).to eq 1
      end
    end

    it "declares the default lockfile's gems" do
      with_checkout_without_plugin_index do |env|
        lockfile = File.read("Gemfile.lock")

        invoke_bundler("check", env:)

        expect(concurrent_ruby_version(env)).to eq "1.1.10"
        expect(File.read("Gemfile.lock")).to eq lockfile
      end
    end

    it "declares the gems of the lockfile that BUNDLE_LOCKFILE selects" do
      with_checkout_without_plugin_index do |env|
        lockfile = File.read("Gemfile.new.lock")
        env = env.merge("BUNDLE_LOCKFILE" => "Gemfile.new.lock")

        invoke_bundler("check", env:)

        expect(concurrent_ruby_version(env)).to eq "1.2.2"
        expect(File.read("Gemfile.new.lock")).to eq lockfile
      end
    end
  end
end

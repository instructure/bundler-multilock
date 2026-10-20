# frozen_string_literal: true

require "bundler/multilock/check"

describe Bundler::Multilock::Check do
  describe "#dependency_options" do
    let(:linux) { Gem::Platform.new("x86_64-linux") }
    let(:darwin) { Gem::Platform.new("arm64-darwin") }
    let(:java) { Gem::Platform.new("universal-java") }
    let(:platforms) { [Gem::Platform::RUBY, linux, darwin, java] }
    let(:definition_class) { Struct.new(:dependencies, :platforms) }

    def dependency(name, **options)
      Bundler::Dependency.new(name, nil, options.transform_keys(&:to_s))
    end

    def options_for(*dependencies)
      described_class.new.send(:dependency_options, definition_class.new(dependencies, platforms))
    end

    it "doesn't have options for dependencies without any" do
      expect(options_for(dependency("a"), dependency("b"))).to eq({})
    end

    it "has the platforms of a dependency that's limited to some" do
      expect(options_for(dependency("a", platforms: :jruby)))
        .to eq({ "a" => [{ force_ruby: false, platforms: [java] }] })
      expect(options_for(dependency("a", platforms: :ruby)))
        .to eq({ "a" => [{ force_ruby: false, platforms: [Gem::Platform::RUBY, linux, darwin] }] })
    end

    it "has if a dependency is forced to the ruby platform" do
      expect(options_for(dependency("a", force_ruby_platform: true)))
        .to eq({ "a" => [{ force_ruby: true, platforms: nil }] })
    end

    it "has each declaration of a gem that's declared more than once" do
      options = options_for(dependency("a", platforms: :ruby), dependency("a", platforms: :jruby))

      expect(options).to eq({ "a" => [{ force_ruby: false, platforms: [Gem::Platform::RUBY, linux, darwin] },
                                      { force_ruby: false, platforms: [java] }] })
    end

    it "keeps what each declaration is forced to separate" do
      options = options_for(dependency("a", platforms: :ruby, force_ruby_platform: true),
                            dependency("a", platforms: :jruby))

      expect(options).to eq({ "a" => [{ force_ruby: true, platforms: [Gem::Platform::RUBY, linux, darwin] },
                                      { force_ruby: false, platforms: [java] }] })
    end

    it "doesn't limit a gem that's also declared without being limited" do
      expect(options_for(dependency("a"), dependency("a", platforms: :jruby))).to eq({})
      expect(options_for(dependency("a", platforms: :jruby), dependency("a"))).to eq({})
      expect(options_for(dependency("a", force_ruby_platform: true), dependency("a"))).to eq({})
    end

    it "limits a gem that's forced, and not limited, everywhere it's declared" do
      expect(options_for(dependency("a", force_ruby_platform: true), dependency("a", force_ruby_platform: true)))
        .to eq({ "a" => [{ force_ruby: true, platforms: nil }, { force_ruby: true, platforms: nil }] })
    end
  end

  describe "#deep_check" do
    def with_bundler_version(lockfile)
      <<~TEXT
        #{lockfile}
        BUNDLED WITH
           #{Bundler::VERSION}
      TEXT
    end

    # @return [true, false] if the alternate lockfile passes the deep check, when it has to pin
    #   everything that isn't in the parent lockfile
    def deep_check(parent:, alternate:)
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) do
          File.write("Gemfile.lock", with_bundler_version(parent))
          File.write("Gemfile.alt.lock", with_bundler_version(alternate))
          definition = {
            lockfile: Pathname.new(dir).join("Gemfile.alt.lock").realpath,
            parent: Pathname.new(dir).join("Gemfile.lock").realpath,
            enforce_pinned_additional_dependencies: true
          }
          Bundler.ui.silence { described_class.new(check_installed: false).deep_check(definition) }
        end
      end
    end

    it "requires pins for what's only reachable through gems that both lockfiles have" do
      # "a" is the same in both, and depends on "b". the parent only has a platform specific variant of "b",
      # so this "b" is additional, and not just a source variant of what the parent has
      parent = <<~TEXT
        GEM
          remote: https://rubygems.org/
          specs:
            a (1)
              b
            b (1-x86_64-linux)

        PLATFORMS
          ruby
          x86_64-linux

        DEPENDENCIES
          a
      TEXT
      alternate = <<~TEXT
        GEM
          remote: https://rubygems.org/
          specs:
            a (1)
              b
            b (2)

        PLATFORMS
          ruby
          x86_64-linux

        DEPENDENCIES
          a
      TEXT

      expect(deep_check(parent:, alternate:)).to be false
    end

    context "with a source variant of a gem that the parent only has a platform specific variant of" do
      # "n" is a platform specific gem in the parent, with a source variant in the alternate lockfile that
      # also needs "m", which the parent doesn't have
      let(:parent) do
        <<~TEXT
          GEM
            remote: https://rubygems.org/
            specs:
              n (1-x86_64-linux)

          PLATFORMS
            x86_64-linux

          DEPENDENCIES
            n
        TEXT
      end

      it "doesn't require pins for the source variant, or what only it needs" do
        alternate = <<~TEXT
          GEM
            remote: https://rubygems.org/
            specs:
              m (1)
              n (1)
                m
              n (1-x86_64-linux)

          PLATFORMS
            x86_64-linux

          DEPENDENCIES
            n
        TEXT

        expect(deep_check(parent:, alternate:)).to be true
      end

      it "still requires pins for what's unreachable for other reasons than the source variant being excluded" do
        # "unused" isn't needed by anything, with or without the source variant of "n", so it's not just there
        # for that variant, and doesn't get the same exemption from needing to be pinned
        alternate = <<~TEXT
          GEM
            remote: https://rubygems.org/
            specs:
              m (1)
              n (1)
                m
              n (1-x86_64-linux)
              unused (1)

          PLATFORMS
            x86_64-linux

          DEPENDENCIES
            n
        TEXT

        expect(deep_check(parent:, alternate:)).to be false
      end
    end
  end
end

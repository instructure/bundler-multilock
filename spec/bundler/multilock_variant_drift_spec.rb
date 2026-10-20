# frozen_string_literal: true

describe Bundler::Multilock do
  describe ".variant_drift" do
    let(:ruby) { Gem::Platform::RUBY }
    let(:linux) { Gem::Platform.new("x86_64-linux") }
    let(:darwin) { Gem::Platform.new("arm64-darwin") }
    let(:rubygems) { :rubygems }
    let(:spec_class) do
      Struct.new(:name, :version, :platform, :source, :dependencies) do
        include Bundler::MatchPlatform

        def required_ruby_version
          Gem::Requirement.default
        end

        def required_rubygems_version
          Gem::Requirement.default
        end
      end
    end

    def variant(name, version, platform, source = rubygems, dependencies: [])
      spec_class.new(name, version, platform, source, dependencies.map { |dependency| Gem::Dependency.new(dependency) })
    end

    def drift(specs, parent_specs, platforms, parent_platforms, **)
      described_class.variant_drift(specs, parent_specs, platforms, parent_platforms, **)
    end

    # (when both lockfiles list the same platforms)
    def drift_on(platforms, specs, parent_specs, **)
      drift(specs, parent_specs, platforms, platforms, **)
    end

    it "finds variants of platforms that only one of the lockfiles lists" do
      mine = [variant("a", "1", linux), variant("a", "1", darwin)]
      parents = [variant("a", "1", linux)]

      stale, missing = drift(mine, parents, [linux], [linux])
      expect(stale).to eq([mine[1]])
      expect(missing).to be_empty

      stale, missing = drift(parents, mine, [linux, darwin], [linux, darwin])
      expect(stale).to be_empty
      expect(missing).to eq([mine[1]])
    end

    it "doesn't consider a platform that's equivalent to another to be different" do
      gnu = Gem::Platform.new("x86_64-linux-gnu")

      stale, missing = drift([variant("a", "1", gnu)], [variant("a", "1", linux)], [gnu], [linux])
      expect(stale).to be_empty
      expect(missing).to be_empty
    end

    it "doesn't consider a source variant to be stale for a version the parent has" do
      mine = [variant("a", "1", linux), variant("a", "1", ruby)]

      stale, = drift(mine, [variant("a", "1", linux)], [linux], [linux])
      expect(stale).to be_empty
    end

    it "considers source variants of versions only left behind next to the parent's to be stale" do
      mine = [variant("a", "1", linux), variant("a", "0.9", ruby), variant("b", "1", ruby)]
      parents = [variant("a", "1", linux)]

      stale, = drift(mine, parents, [linux], [linux])
      expect(stale).to eq([mine[1]])
    end

    it "doesn't look for variants that the parent doesn't list the platform for" do
      mine = [variant("a", "1", linux)]
      parents = [variant("a", "1", linux), variant("a", "1", ruby)]

      _, missing = drift(mine, parents, [linux, ruby], [linux])
      expect(missing).to be_empty

      _, missing = drift(mine, parents, [linux, ruby], [linux, ruby])
      expect(missing).to eq([parents[1]])
    end

    it "doesn't mind gems that are needed, but aren't in the lockfile" do
      mine = [variant("a", "1", linux, dependencies: %w[bundler missing])]
      parents = [variant("a", "1", linux, dependencies: %w[bundler missing]), variant("a", "1", darwin)]

      _, missing = drift_on([linux, darwin], mine, parents, dependency_names: %w[a not_locked])
      expect(missing).to eq([parents[1]])
    end

    it "ignores variants of gems that this lockfile uses a different variant of, with force_ruby_platform" do
      mine = [variant("a", "1", ruby)]
      parents = [variant("a", "1", linux), variant("a", "1", ruby)]
      options = { "a" => [{ force_ruby: true, platforms: nil }] }

      _, missing = drift(mine, parents, [linux], [linux], dependency_names: %w[a], dependency_options: options)
      expect(missing).to be_empty

      _, missing = drift(mine, parents, [linux], [linux], dependency_names: %w[a])
      expect(missing).to eq([parents[0]])
    end

    it "ignores variants of gems that are only for other platforms" do
      parents = [variant("a", "1", linux), variant("a", "1", darwin)]
      options = { "a" => [{ force_ruby: false, platforms: [darwin] }] }

      mine = [variant("a", "1", darwin)]
      _, missing = drift_on([linux, darwin], mine, parents, dependency_names: %w[a], dependency_options: options)
      expect(missing).to be_empty

      options = { "a" => [{ force_ruby: false, platforms: [linux, darwin] }] }
      mine = [variant("a", "1", ruby), variant("a", "1", darwin)]
      _, missing = drift_on([linux, darwin], mine, parents, dependency_names: %w[a], dependency_options: options)
      expect(missing).to eq([parents[0]])
    end

    it "still finds leftover variants of gems that are limited to some platforms" do
      mine = [variant("a", "1", linux), variant("a", "1", darwin)]
      parents = [variant("a", "1", linux)]
      options = { "a" => [{ force_ruby: false, platforms: [ruby, linux, darwin] }] }

      stale, = drift_on([linux], mine, parents, dependency_names: %w[a], dependency_options: options)
      expect(stale).to eq([mine[1]])
    end

    it "uses what each declaration of a gem that's declared more than once is forced to" do
      java = Gem::Platform.new("universal-java")
      mine = [variant("a", "1", ruby)]
      parents = [variant("a", "1", ruby), variant("a", "1", linux)]
      options = { "a" => [{ force_ruby: true, platforms: [ruby, linux] }, { force_ruby: false, platforms: [java] }] }

      _, missing = drift_on([linux, java], mine, parents, dependency_names: %w[a], dependency_options: options)
      expect(missing).to be_empty

      # (but it's not forced on the other platforms)
      parents = [variant("a", "1", ruby), variant("a", "1", java)]
      _, missing = drift_on([linux, java], mine, parents, dependency_names: %w[a], dependency_options: options)
      expect(missing).to eq([parents[1]])
    end

    context "with a universal CPU" do
      let(:universal) { Gem::Platform.new("universal-darwin") }
      let(:x86_darwin) { Gem::Platform.new("x86_64-darwin") }

      it "doesn't consider a concrete CPU to be the same as a universal one" do
        expect(described_class.same_platform?(darwin, universal)).to be false
        expect(described_class.same_platform?(universal, darwin)).to be false
        expect(described_class.same_platform?(darwin, Gem::Platform.new("arm64-darwin-25"))).to be true
      end

      it "finds a missing universal variant when only a variant for one of the CPUs is there" do
        mine = [variant("a", "1", darwin)]
        parents = [variant("a", "1", universal)]

        _, missing = drift_on([darwin, x86_darwin], mine, parents, dependency_names: %w[a])
        expect(missing).to eq(parents)
      end

      it "doesn't need the universal variant for the only CPU that has a variant that can be used" do
        mine = [variant("a", "1", darwin)]
        parents = [variant("a", "1", universal)]

        _, missing = drift_on([darwin], mine, parents, dependency_names: %w[a])
        expect(missing).to be_empty
      end

      it "finds a leftover variant for a CPU that the parent doesn't list, next to a universal variant" do
        mine = [variant("a", "1", universal), variant("a", "1", darwin)]
        parents = [variant("a", "1", universal)]

        stale, = drift_on([x86_darwin], mine, parents, dependency_names: %w[a])
        expect(stale).to eq([mine[1]])
      end
    end

    context "with variants that depend on different gems" do
      let(:windows) { Gem::Platform.new("x64-mingw-ucrt") }

      # only a's Linux variant needs b
      let(:mine) do
        [variant("a", "1", linux, dependencies: %w[b]), variant("a", "1", windows), variant("b", "1", linux)]
      end
      let(:parents) { mine + [variant("b", "1", windows)] }

      it "only needs the variants of what the variant that's used depends on" do
        _, missing = drift(mine, parents, [linux, windows], [linux, windows], dependency_names: %w[a])
        expect(missing).to be_empty
      end

      it "still finds variants it needs that are missing" do
        mine = [
          variant("a", "1", linux, dependencies: %w[b]),
          variant("a", "1", windows, dependencies: %w[b]),
          variant("b", "1", linux)
        ]

        _, missing = drift(mine, parents, [linux, windows], [linux, windows], dependency_names: %w[a])
        expect(missing).to eq([parents.last])
      end

      it "still only needs what the variant that's used depends on, for a gem limited to some platforms" do
        options = { "a" => [{ force_ruby: false, platforms: [linux, windows] }] }

        _, missing = drift(
          mine,
          parents,
          [linux, windows],
          [linux, windows],
          dependency_names: %w[a],
          dependency_options: options
        )
        expect(missing).to be_empty
      end

      it "needs them for a gem that's also a dependency of its own" do
        _, missing = drift(mine, parents, [linux, windows], [linux, windows], dependency_names: %w[a b])
        expect(missing).to eq([parents.last])
      end
    end

    it "keeps using the source variant of a gem that's forced, even when something else needs it too" do
      mine = [variant("a", "1", ruby, dependencies: %w[b]), variant("b", "1", ruby)]
      parents = mine + [variant("b", "1", linux)]
      options = { "b" => [{ force_ruby: true, platforms: nil }] }

      _, missing = drift(mine, parents, [linux], [linux], dependency_names: %w[a b], dependency_options: options)
      expect(missing).to be_empty

      _, missing = drift(mine, parents, [linux], [linux], dependency_names: %w[a b])
      expect(missing).to eq([parents.last])
    end

    it "needs the source variant of a gem for platforms that it doesn't have a platform specific variant for" do
      windows = Gem::Platform.new("x64-mingw-ucrt")
      mine = [variant("a", "1", linux)]
      parents = [variant("a", "1", linux), variant("a", "1", ruby)]

      # (as long as the ruby platform is listed)
      _, missing = drift(mine, parents, [linux, windows], [linux, windows], dependency_names: %w[a])
      expect(missing).to be_empty

      _, missing = drift(mine, parents, [linux, windows, ruby], [linux, windows, ruby], dependency_names: %w[a])
      expect(missing).to eq([parents[1]])
    end

    it "ignores gems from a different source than the parent's" do
      other = :other
      mine = [variant("a", "1", ruby, other)]
      parents = [variant("a", "1", linux)]

      _, missing = drift(mine, parents, [linux], [linux])
      expect(missing).to be_empty

      mine = [variant("a", "1", ruby)]
      _, missing = drift(mine, parents, [linux], [linux])
      expect(missing).to eq(parents)
    end

    it "compares the sources starting with the spec from this lockfile, in both directions" do
      # (the sources of paths are relative to different lockfiles, so which is which matters)
      from_this_lockfile = ->(spec, parent_spec) { spec.source == :this && parent_spec.source == :parent }

      mine = [variant("a", "1", linux, :this), variant("a", "1", darwin, :this)]
      parents = [variant("a", "1", linux, :parent)]
      stale, = drift(mine, parents, [linux], [linux], same_source: from_this_lockfile)
      expect(stale).to eq([mine[1]])

      mine = [variant("a", "1", linux, :this)]
      parents = [variant("a", "1", linux, :parent), variant("a", "1", darwin, :parent)]
      _, missing = drift(mine, parents, [linux, darwin], [linux, darwin], same_source: from_this_lockfile)
      expect(missing).to eq([parents[1]])
    end

    context "with musl" do
      let(:musl) { Gem::Platform.new("x86_64-linux-musl") }
      let(:gnu) { Gem::Platform.new("x86_64-linux-gnu") }

      it "doesn't consider musl to be the same as other Linux platforms" do
        expect(described_class.same_platform?(linux, musl)).to be false
        expect(described_class.same_platform?(musl, linux)).to be false
        expect(described_class.same_platform?(gnu, musl)).to be false
        expect(described_class.same_platform?(linux, gnu)).to be true
      end

      it "finds leftover musl variants when the parent only lists the generic Linux platform" do
        mine = [variant("a", "1", linux), variant("a", "1", musl)]
        parents = [variant("a", "1", linux)]

        stale, = drift(mine, parents, [linux], [linux])
        expect(stale).to eq([mine[1]])
      end

      it "finds missing musl variants when only the generic Linux variant is there" do
        mine = [variant("a", "1", linux)]
        parents = [variant("a", "1", linux), variant("a", "1", musl)]

        _, missing = drift(mine, parents, [linux, musl], [linux, musl])
        expect(missing).to eq([parents[1]])
      end

      it "uses the generic Linux variant for a musl platform" do
        # (a generic Linux gem can be used on musl, but not the other way around)
        expect(described_class.matching_platforms([musl], linux)).to eq([musl])
        expect(described_class.matching_platforms([linux], musl)).to be_empty
        expect(described_class.matching_platforms([gnu, musl], linux)).to eq([gnu, musl])
        expect(described_class.matching_platforms([gnu, musl], gnu)).to eq([gnu])
        expect(described_class.matching_platforms([linux, gnu], musl)).to be_empty
      end

      it "only matches the source variant to the listed ruby platform" do
        expect(described_class.matching_platforms([linux, musl], ruby)).to be_empty
        expect(described_class.matching_platforms([linux, ruby], ruby)).to eq([ruby])
        expect(described_class.matching_platforms([ruby], linux)).to be_empty
      end

      it "finds the generic Linux variant that's missing when only musl is listed" do
        mine = [variant("a", "1", ruby)]
        parents = [variant("a", "1", linux)]

        _, missing = drift(mine, parents, [musl], [musl], dependency_names: %w[a])
        expect(missing).to eq(parents)
      end

      it "doesn't find a musl variant to be covered by only the generic Linux platform listed" do
        mine = [variant("a", "1", linux), variant("a", "1", musl)]
        parents = [variant("a", "1", linux)]

        stale, missing = drift(mine, parents, [linux], [linux], dependency_names: %w[a])
        expect(stale).to eq([mine[1]])
        expect(missing).to be_empty
      end

      it "doesn't need the source variant for a musl platform that has the generic Linux variant" do
        mine = [variant("a", "1", linux)]
        parents = [variant("a", "1", linux), variant("a", "1", ruby)]

        _, missing = drift(mine, parents, [musl], [musl], dependency_names: %w[a])
        expect(missing).to be_empty
      end
    end
  end

  describe ".gems_needed_on" do
    let(:ruby) { Gem::Platform::RUBY }
    let(:linux) { Gem::Platform.new("x86_64-linux") }
    let(:windows) { Gem::Platform.new("x64-mingw-ucrt") }
    let(:spec_class) do
      Struct.new(:name, :platform, :dependencies) do
        include Bundler::MatchPlatform

        def required_ruby_version
          Gem::Requirement.default
        end

        def required_rubygems_version
          Gem::Requirement.default
        end
      end
    end

    def spec_for(name, platform, *dependencies)
      spec_class.new(name, platform, dependencies.map { |dependency| Gem::Dependency.new(dependency) })
    end

    def needed(specs, platform, dependency_names, options = {})
      described_class.gems_needed_on(platform, specs.group_by(&:name), dependency_names, options)
    end

    it "follows dependencies" do
      specs = [spec_for("a", ruby, "b"), spec_for("b", ruby, "c"), spec_for("c", ruby), spec_for("d", ruby)]

      expect(needed(specs, linux, %w[a])).to eq({ "a" => false, "b" => false, "c" => false })
    end

    it "only follows the dependencies of the variant that's used for the platform" do
      specs = [spec_for("a", linux, "b"), spec_for("a", windows, "c"), spec_for("b", ruby), spec_for("c", ruby)]

      expect(needed(specs, linux, %w[a])).to eq({ "a" => false, "b" => false })
      expect(needed(specs, windows, %w[a])).to eq({ "a" => false, "c" => false })
    end

    it "falls back to the source variant" do
      specs = [spec_for("a", linux, "b"), spec_for("a", ruby, "c"), spec_for("b", ruby), spec_for("c", ruby)]

      expect(needed(specs, windows, %w[a])).to eq({ "a" => false, "c" => false })
    end

    it "only has the dependencies that are for the platform" do
      specs = [spec_for("a", ruby), spec_for("b", ruby)]
      options = { "b" => [{ force_ruby: false, platforms: [windows] }] }

      expect(needed(specs, linux, %w[a b], options)).to eq({ "a" => false })
      expect(needed(specs, windows, %w[a b], options)).to eq({ "a" => false, "b" => false })
    end

    it "needs what a dependency that isn't for the platform is needed by something else for" do
      specs = [spec_for("a", ruby, "b"), spec_for("b", ruby)]
      options = { "b" => [{ force_ruby: false, platforms: [windows] }] }

      expect(needed(specs, linux, %w[a b], options)).to eq({ "a" => false, "b" => false })
    end

    it "uses the source variant of gems that are forced, even when something else needs them" do
      specs = [spec_for("a", linux, "b"), spec_for("b", linux, "c"), spec_for("b", ruby), spec_for("c", ruby)]
      options = { "b" => [{ force_ruby: true, platforms: nil }] }

      expect(needed(specs, linux, %w[a b], options)).to eq({ "a" => false, "b" => true })
    end

    it "forces the source variant only for the platforms of the declarations that force it" do
      java = Gem::Platform.new("universal-java")
      specs = [
        spec_for("a", linux, "b"),
        spec_for("a", java, "c"),
        spec_for("a", ruby, "d"),
        spec_for("b", ruby),
        spec_for("c", ruby),
        spec_for("d", ruby)
      ]
      options = { "a" => [{ force_ruby: true, platforms: [ruby, linux] }, { force_ruby: false, platforms: [java] }] }

      expect(needed(specs, linux, %w[a], options)).to eq({ "a" => true, "d" => false })
      expect(needed(specs, java, %w[a], options)).to eq({ "a" => false, "c" => false })
    end

    it "handles dependencies that depend on each other" do
      specs = [spec_for("a", ruby, "b"), spec_for("b", ruby, "a")]

      expect(needed(specs, linux, %w[a])).to eq({ "a" => false, "b" => false })
    end

    it "needs every gem when the dependencies aren't known" do
      specs = [spec_for("a", ruby), spec_for("b", ruby)]

      expect(needed(specs, linux, nil)).to eq({ "a" => false, "b" => false })
    end
  end

  describe ".same_source?" do
    let(:spec_class) { Struct.new(:source) }
    let(:lockfile) { Pathname.new("/project/other/Gemfile.lock") }
    let(:parent_lockfile) { Pathname.new("/project/Gemfile.lock") }

    def same_source?(path, parent_path, lockfile_name, parent_lockfile_name)
      spec = spec_class.new(Bundler::Source::Path.new("path" => path))
      parent_spec = spec_class.new(Bundler::Source::Path.new("path" => parent_path))
      described_class.same_source?(spec, parent_spec, lockfile_name, parent_lockfile_name)
    end

    it "compares paths relative to their own lockfiles" do
      expect(same_source?("../gems/shared", "gems/shared", lockfile, parent_lockfile)).to be true
      expect(same_source?("../gems/shared", "gems/other", lockfile, parent_lockfile)).to be false
    end

    it "compares paths that were already rebased to be relative to the same lockfile" do
      # (what the parent lockfile's specs are like while syncing another lockfile)
      expect(same_source?("../gems/shared", "../gems/shared", lockfile, lockfile)).to be true
      expect(same_source?("../gems/shared", "../gems/shared", lockfile, parent_lockfile)).to be false
    end
  end
end

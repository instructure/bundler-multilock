# frozen_string_literal: true

require "bundler/multilock/cache"

describe Bundler::Multilock, ".spec_precedences" do
  def lockfile(specs, dependencies, platforms)
    <<~TEXT
      GEM
        remote: https://rubygems.org/
        specs:
      #{specs.gsub(/^(?=.)/, "    ")}

      PLATFORMS
      #{platforms.gsub(/^(?=.)/, "  ")}

      DEPENDENCIES
      #{dependencies.gsub(/^(?=.)/, "  ")}
    TEXT
  end

  # @param dependencies [String] the DEPENDENCIES section of the lockfile
  # @param parent_dependencies [String] the DEPENDENCIES section of the parent lockfile, if different
  # @param platforms [String] the PLATFORMS section of the lockfile
  # @param parent_platforms [String] the PLATFORMS section of the parent lockfile, if different
  # @param requirements [Hash<String, String>, nil] the requirements of the alternate's Gemfile, if different
  # @return [Array(Hash<String, Symbol>, Set<String>)] which version wins for each gem, and what to unlock
  def sync(own,
           parent,
           conflicts:,
           dependencies: "a",
           parent_dependencies: dependencies,
           platforms: "ruby",
           parent_platforms: platforms,
           requirements: nil)
    Dir.mktmpdir do |dir|
      dir = Pathname.new(dir)
      dir.join("Gemfile.alt.lock").write(lockfile(own, dependencies, platforms))
      dir.join("Gemfile.lock").write(lockfile(parent, parent_dependencies, parent_platforms))

      options = {}
      if requirements
        options[:gemfile_requirements] = requirements.transform_values { |value| Gem::Requirement.new(value) }
      end

      described_class.spec_precedences(Bundler::Multilock::Cache.new,
                                       dir.join("Gemfile.alt.lock"),
                                       dir.join("Gemfile.lock"),
                                       conflicts.to_set,
                                       **options)
    end
  end

  def precedences(...)
    sync(...).first
  end

  def unlocked(...)
    sync(...).last.to_a.sort
  end

  it "follows the parent for what an out of sync gem depends on" do
    result = precedences(<<~TEXT, <<~TEXT, conflicts: %w[a])
      a (1)
        b (>= 1)
      b (1)
    TEXT
      a (2)
        b (>= 1)
      b (2)
    TEXT

    expect(result).to eq("a" => :parent, "b" => :parent)
  end

  it "keeps what something that's not out of sync requires, if the parent can't use it either" do
    # b is only in this lockfile, and requires c to stay at 1, which the parent can't have either
    result = sync(<<~TEXT, <<~TEXT, conflicts: %w[a], dependencies: "a\nb", parent_dependencies: "a\nc (>= 2)")
      a (1)
        c (>= 1)
      b (1)
        c (= 1)
      c (1)
    TEXT
      a (2)
        c (>= 1)
      c (2)
    TEXT

    expect(result).to eq([{ "a" => :parent, "c" => :self }, Set.new])
  end

  it "follows the parent for gems that only a gem that follows the parent was holding back" do
    # b changes versions because a does (a is out of sync, b is not), and b was the only thing
    # requiring c to be at version 1
    result = precedences(<<~TEXT, <<~TEXT, conflicts: %w[a])
      a (1)
        b (= 1)
        c (>= 1)
      b (1)
        c (= 1)
      c (1)
    TEXT
      a (2)
        b (= 2)
        c (>= 1)
      b (2)
        c (= 2)
      c (2)
    TEXT

    expect(result).to eq("a" => :parent, "b" => :parent, "c" => :parent)
  end

  it "keeps requirements of gems that are out of sync, but that keep their own version" do
    # a, b and c are all out of sync, but d (only in this lockfile) requires b to stay the same, which the
    # parent can't have either, so b has to keep its own version, and with it its requirement of c
    own = <<~TEXT
      a (1)
        b (>= 1)
      b (1)
        c (= 1)
      c (1)
      d (1)
        b (= 1)
    TEXT
    parent = <<~TEXT
      a (2)
        b (>= 1)
      b (2)
        c (>= 1)
      c (2)
    TEXT
    result = sync(own, parent, conflicts: %w[a b c], dependencies: "a\nd", parent_dependencies: "a\nb (>= 2)\nc (>= 2)")

    expect(result.first).to include("a" => :parent, "b" => :self, "c" => :self)
  end

  it "keeps the requirements of gems that keep their own version, even when no gem is known to be out of sync" do
    own = <<~TEXT
      a (1)
        b (>= 1)
      b (1)
        c (= 1)
      c (1)
      d (1)
        b (= 1)
    TEXT
    parent = <<~TEXT
      a (2)
        b (>= 1)
      b (2)
        c (>= 1)
      c (2)
    TEXT
    result = sync(own, parent, conflicts: [], dependencies: "a\nd", parent_dependencies: "a\nb (>= 2)\nc (>= 2)")

    expect(result.first).to include("b" => :self, "c" => :self)
  end

  it "uses the requirements from the Gemfile, instead of the lockfile's, which could be about to change" do
    # the lockfile still says b = 1, but the Gemfile has been loosened
    own = <<~TEXT
      a (1)
        b (>= 1)
      b (1)
    TEXT
    parent = <<~TEXT
      a (2)
        b (>= 1)
      b (2)
    TEXT

    options = { conflicts: %w[a], dependencies: "a\nb (= 1)", parent_dependencies: "a\nb" }
    stale = precedences(own, parent, **options)
    loosened = precedences(own, parent, **options, requirements: { "a" => ">= 0", "b" => ">= 1" })
    still_pinned = precedences(own, parent, **options, requirements: { "a" => ">= 0", "b" => "= 1" })

    expect(stale).to include("b" => :self)
    expect(loosened).to include("b" => :parent)
    expect(still_pinned).to include("b" => :self)
  end

  it "uses the requirements from the Gemfile to decide if a gem is intentionally different" do
    # the lockfile still says a = 1, which the parent's a >= 2 can't have, but the Gemfile has been loosened
    own = "a (1)\n"
    parent = "a (2)\n"
    options = { conflicts: [], dependencies: "a (= 1)", parent_dependencies: "a (>= 2)" }

    expect(precedences(own, parent, **options)).to eq("a" => :self)
    expect(precedences(own, parent, **options, requirements: { "a" => ">= 1" })).to eq("a" => :parent)
  end

  it "follows the parent for what a gem depends on, even if the gem has the same version" do
    # a git gem can change its dependencies without changing its version
    result = precedences(<<~TEXT, <<~TEXT, conflicts: [])
      a (1)
        b (= 1)
      b (1)
    TEXT
      a (1)
        b (>= 1)
      b (2)
    TEXT

    expect(result).to eq("a" => :parent, "b" => :parent)
  end

  it "ignores requirements from gems that won't be needed any more" do
    # b is only needed by a1, so c doesn't need to stay at 1 for it
    result = precedences(<<~TEXT, <<~TEXT, conflicts: [])
      a (1)
        b (= 1)
        c (>= 1)
      b (1)
        c (= 1)
      c (1)
    TEXT
      a (2)
        c (>= 1)
      c (2)
    TEXT

    expect(result).to eq("a" => :parent, "c" => :parent)
  end

  it "keeps requirements from gems that are still needed, even if the gem that needed them changes" do
    # b is only in this lockfile, but it's in the Gemfile, and requires c to stay at 1
    result = precedences(<<~TEXT, <<~TEXT, conflicts: [], dependencies: "a\nb", parent_dependencies: "a\nc (>= 2)")
      a (1)
        b (= 1)
        c (>= 1)
      b (1)
        c (= 1)
      c (1)
    TEXT
      a (2)
        c (>= 1)
      c (2)
    TEXT

    expect(result).to include("c" => :self)
  end

  it "ignores requirements from gems that won't be needed any more, when deciding if a gem is different on purpose" do
    # b is only needed by a1, so it doesn't make c differ on purpose
    result = precedences(<<~TEXT, <<~TEXT, conflicts: [])
      a (1)
        b (= 1)
      b (1)
        c (= 1)
      c (1)
    TEXT
      a (2)
        c (>= 2)
      c (2)
    TEXT

    expect(result).to eq("a" => :parent, "c" => :parent)
  end

  it "ignores the requirements of gems that are going to be unlocked" do
    # d requires b < 2 (so it has to be unlocked), and it requires c = 1, but it won't, once it's updated
    own = <<~TEXT
      b (1)
      c (1)
      d (1)
        b (< 2)
        c (= 1)
    TEXT
    parent = <<~TEXT
      b (2)
      c (2)
    TEXT

    expect(sync(own, parent, conflicts: [], dependencies: "b\nc\nd", parent_dependencies: "b\nc (>= 2)"))
      .to eq([{ "b" => :parent, "c" => :parent }, Set["d"]])
  end

  it "unlocks what's in the way of a gem that a gem following the parent requires to change" do
    # a2 requires b = 2, so b can't stay at 1 even though that's what d requires. d has to be updated
    own = <<~TEXT
      a (1)
        b (= 1)
      b (1)
      d (1)
        b (= 1)
    TEXT
    parent = <<~TEXT
      a (2)
        b (= 2)
      b (2)
    TEXT

    expect(sync(own, parent, conflicts: [], dependencies: "a\nd", parent_dependencies: "a"))
      .to eq([{ "a" => :parent, "b" => :parent }, Set["d"]])
  end

  it "ignores what a variant of a gem that isn't replaced requires, if nothing needs the gem any more" do
    # b's ruby variant is kept, but b isn't needed by a2 any more, so it doesn't require c = 1 either
    own = <<~TEXT
      a (1)
        b (>= 1)
        c (>= 1)
      b (1)
        c (= 1)
      b (1-java)
      c (1)
    TEXT
    parent = <<~TEXT
      a (2)
        c (>= 1)
      b (1-java)
      c (2)
    TEXT

    result = precedences(own, parent, conflicts: [], parent_dependencies: "a\nb\nc (>= 2)")

    expect(result).to include("c" => :parent)
  end

  it "checks every platform variant of a gem, regardless of their order" do
    ruby = <<~TEXT
      a (1)
    TEXT
    java = <<~TEXT
      a (1-java)
    TEXT
    parent = <<~TEXT
      a (1)
      a (2-java)
    TEXT

    [ruby + java, java + ruby].each do |own|
      # the Gemfile pins a, which the parent's java variant of a doesn't satisfy
      result = precedences(own, parent, conflicts: [], requirements: { "a" => "= 1" })

      expect(result).to eq("a" => :self)
    end
  end

  it "unlocks what's in the way of what a gem that's only in the parent requires" do
    # a2 requires b, which isn't in this lockfile, and requires c = 2, which d1 (requiring c = 1) is in the way of
    own = <<~TEXT
      a (1)
      c (1)
      d (1)
        c (= 1)
    TEXT
    parent = <<~TEXT
      a (2)
        b (>= 1)
      b (1)
        c (= 2)
      c (2)
    TEXT

    expect(sync(own, parent, conflicts: [], dependencies: "a\nd", parent_dependencies: "a"))
      .to eq([{ "a" => :parent, "c" => :parent }, Set["d"]])
  end

  it "only needs what the variants of a gem that are used need" do
    # this lockfile only has the ruby variant of a, so it doesn't need b, which only a2's java variant needs
    own = <<~TEXT
      a (1)
        b (>= 1)
      b (1)
        c (= 1)
      c (1)
    TEXT
    parent = <<~TEXT
      a (2)
        c (>= 1)
      a (2-java)
        b (>= 1)
      b (1-java)
      c (2)
    TEXT

    result = precedences(own, parent, conflicts: [], parent_dependencies: "a\nc (>= 2)")

    expect(result).to include("c" => :parent)
  end

  it "doesn't force a gem to change for what a gem that won't be needed any more requires" do
    # b is only needed by a1 in this lockfile, so b2 requiring c = 2 doesn't matter, and d1 can stay
    own = <<~TEXT
      a (1)
        b (>= 1)
      b (1)
      c (1)
      d (1)
        c (= 1)
    TEXT
    parent = <<~TEXT
      a (2)
      b (2)
        c (= 2)
      c (2)
    TEXT

    result = sync(own, parent, conflicts: [], dependencies: "a\nd", parent_dependencies: "a\nb\nc (>= 2)")

    expect(result.first).to include("c" => :self)
    expect(result.last).to be_empty
  end

  it "only forces a gem to change for what the variants of a gem that are used require" do
    # this lockfile only has the ruby variant of a, which doesn't require c = 2
    own = <<~TEXT
      a (1)
        c (>= 1)
      c (1)
      d (1)
        c (= 1)
    TEXT
    parent = <<~TEXT
      a (2)
        c (>= 1)
      a (2-java)
        c (= 2)
      c (2)
    TEXT

    result = sync(own, parent, conflicts: [], dependencies: "a\nd", parent_dependencies: "a\nc (>= 2)")

    expect(result.first).to include("c" => :self)
    expect(result.last).to be_empty
  end

  it "only brings along gems that the variants of a gem that are used require" do
    # b is only required by the java variant of a, which this lockfile doesn't have, so it doesn't matter
    own = <<~TEXT
      a (1)
      c (1)
      d (1)
        c (= 1)
    TEXT
    parent = <<~TEXT
      a (2)
      a (2-java)
        b (>= 1)
      b (1)
        c (= 2)
      c (2)
    TEXT

    result = sync(own, parent, conflicts: [], dependencies: "a\nd", parent_dependencies: "a\nc (>= 2)")

    expect(result.first).to include("c" => :self)
    expect(result.last).to be_empty
  end

  it "ignores what variants of a gem that are about to be removed require" do
    # the parent only has java, so after a2's java variant replaces a1's, a1's ruby variant is stale
    own = <<~TEXT
      a (1)
        c (= 1)
      a (1-java)
        c (>= 1)
      c (1)
    TEXT
    parent = <<~TEXT
      a (2-java)
        c (>= 1)
      c (2)
    TEXT

    result = precedences(own,
                         parent,
                         conflicts: [],
                         platforms: "ruby\njava",
                         parent_platforms: "java",
                         parent_dependencies: "a\nc (>= 2)")

    expect(result).to include("c" => :parent)
  end

  it "unlocks what's in the way of what a gem that's newly in the Gemfile, and only in the parent, requires" do
    # b is in this lockfile's Gemfile now, and requires c = 2, which d1 (requiring c = 1) is in the way of
    own = <<~TEXT
      c (1)
      d (1)
        c (= 1)
    TEXT
    parent = <<~TEXT
      b (1)
        c (= 2)
      c (2)
    TEXT

    result = sync(own,
                  parent,
                  conflicts: [],
                  dependencies: "c\nd",
                  parent_dependencies: "b\nc",
                  requirements: { "b" => ">= 0", "c" => ">= 0", "d" => ">= 0" })

    expect(result).to eq([{ "c" => :parent }, Set["d"]])
  end

  it "ignores what a gem that's only in the parent requires, if the Gemfile can't use its version" do
    # the Gemfile wants b = 1, so b2 (the parent's), requiring c = 2, won't be used
    own = <<~TEXT
      c (1)
      d (1)
        c (= 1)
    TEXT
    parent = <<~TEXT
      b (2)
        c (= 2)
      c (2)
    TEXT

    result = sync(own,
                  parent,
                  conflicts: [],
                  dependencies: "c\nd",
                  parent_dependencies: "b\nc",
                  requirements: { "b" => "= 1", "c" => ">= 0", "d" => ">= 0" })

    expect(result).to eq([{ "c" => :self }, Set.new])
  end

  it "unlocks what's in the way of a gem that a new version of a gem requires" do
    # a1 didn't depend on b, but a2 requires b = 2, which d1 (requiring b = 1) is in the way of
    own = <<~TEXT
      a (1)
      b (1)
      d (1)
        b (= 1)
    TEXT
    parent = <<~TEXT
      a (2)
        b (= 2)
      b (2)
    TEXT

    expect(sync(own, parent, conflicts: [], dependencies: "a\nd", parent_dependencies: "a"))
      .to eq([{ "a" => :parent, "b" => :parent }, Set["d"]])
  end

  it "keeps what a variant of a gem that isn't replaced requires" do
    # a2's ruby variant is kept, since the parent doesn't have one, so b is still needed (and so is c = 1)
    own = <<~TEXT
      a (2)
        b (>= 1)
      a (1-java)
      b (1)
        c (= 1)
      c (1)
    TEXT
    parent = <<~TEXT
      a (2-java)
      c (2)
    TEXT

    result = precedences(own, parent, conflicts: [], parent_dependencies: "a\nc (>= 2)")

    expect(result).to include("c" => :self)
  end

  it "keeps what a variant of a gem that isn't replaced requires, even if other variants are" do
    # a2's ruby variant is kept, since the parent doesn't have one, and it requires c = 1
    own = <<~TEXT
      a (2)
        c (= 1)
      a (1-java)
      c (1)
    TEXT
    parent = <<~TEXT
      a (2-java)
      c (2)
    TEXT

    result = precedences(own, parent, conflicts: [], parent_dependencies: "a\nc (>= 2)")

    expect(result).to include("c" => :self)
  end

  context "when a gem that's not out of sync is in the way of syncing another" do
    let(:own) do
      <<~TEXT
        a (1)
          b (>= 1)
        b (1)
        d (1)
          b (< 2)
      TEXT
    end
    let(:parent) do
      <<~TEXT
        a (2)
          b (>= 1)
        b (2)
      TEXT
    end

    it "follows the parent, and unlocks what's in the way" do
      expect(sync(own, parent, conflicts: [], dependencies: "a\nd", parent_dependencies: "a"))
        .to eq([{ "a" => :parent, "b" => :parent }, Set["d"]])
    end

    it "keeps the gem if the parent can't use its version either" do
      expect(sync(own, parent, conflicts: [], dependencies: "a\nd", parent_dependencies: "a\nb (>= 2)"))
        .to eq([{ "a" => :parent, "b" => :self }, Set.new])
    end

    it "keeps the gem if the Gemfile is what's in the way, since that can't be updated" do
      expect(sync(own,
                  parent,
                  conflicts: [],
                  dependencies: "a\nd",
                  parent_dependencies: "a",
                  requirements: { "a" => ">= 0", "b" => "< 2", "d" => ">= 0" }))
        .to eq([{ "a" => :parent, "b" => :self }, Set.new])
    end
  end

  it "follows the parent when any platform variant of a gem changes, regardless of their order" do
    ruby = <<~TEXT
      a (1)
        b (>= 1)
    TEXT
    java = <<~TEXT
      a (1-java)
        b (= 1)
    TEXT
    parent = <<~TEXT
      a (1)
        b (>= 1)
      a (1-java)
        b (>= 1)
      b (2)
    TEXT

    [ruby + java, java + ruby].each do |variants|
      result = precedences("#{variants}b (1)\n", parent, conflicts: [])

      expect(result).to include("b" => :parent)
    end
  end
end

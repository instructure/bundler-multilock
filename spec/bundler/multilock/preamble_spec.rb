# frozen_string_literal: true

describe Bundler::Multilock::Preamble do
  it "injects plugin load commands into the Gemfile when installing" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "injects plugin load commands right after the source, even with comments and blank lines later" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        gem "concurrent-ruby", "1.2.2"

        # a comment
        gem "rake", "13.2.1"
      RUBY

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"

        # a comment
        gem "rake", "13.2.1"
      RUBY
    end
  end

  it "injects plugin load commands on their own line when the Gemfile doesn't end with a newline" do
    with_gemfile("") do
      # (a lone `#` at the very end used to be able to loop forever)
      File.write("Gemfile", %(source "https://rubygems.org"\n#))

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}", timeout: 60)

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"
        #
        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

      RUBY
    end
  end

  it "doesn't inject plugin load commands into a trailing comment without a newline" do
    with_gemfile("") do
      File.write("Gemfile", %(source "https://rubygems.org"\n# the end))

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"
        # the end
        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

      RUBY
    end
  end

  it "removes the unnecessary plugin load command and updates the version requirement" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        plugin "bundler-multilock", "~> 1.2"
        return unless Plugin.installed?("bundler-multilock")

        Plugin.send(:load_plugin, "bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        # frozen_string_literal: true

        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "removes the unnecessary plugin load command without blank lines around it" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "~> 1.2"
        return unless Plugin.installed?("bundler-multilock")
        Plugin.send(:load_plugin, "bundler-multilock")
        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")
        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "replaces all of the version constraints when updating the version requirement" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "~> 1.2", "< 1.5", source: "https://rubygems.org"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}", source: "https://rubygems.org"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "replaces all of the version constraints even with comments between them" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "~> 1.2", # legacy major
               "< 1.5",
               source: "https://rubygems.org"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}",
               source: "https://rubygems.org"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "updates a guard without parentheses, instead of injecting another one" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin 'bundler-multilock', '~> 1.2'
        return unless Plugin.installed? 'bundler-multilock'

        Plugin.send(:load_plugin, 'bundler-multilock')

        gem 'concurrent-ruby', '1.2.2'
      RUBY

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin 'bundler-multilock', '#{plugin_requirement}'
        return unless Plugin.loaded?('bundler-multilock')

        gem 'concurrent-ruby', '1.2.2'
      RUBY
    end
  end

  it "only updates the preamble in code, not in strings, heredocs, or comments" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "~> 1.2"
        return unless Plugin.installed?("bundler-multilock")

        Plugin.send(:load_plugin, "bundler-multilock")

        # plugin "bundler-multilock", "~> 1.2"
        TEMPLATE = <<~GEMFILE
          plugin "bundler-multilock", "~> 1.2"
          return unless Plugin.installed?("bundler-multilock")
          Plugin.send(:load_plugin, "bundler-multilock")
        GEMFILE
        SNIPPET = 'return unless Plugin.installed? "bundler-multilock"'

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

        # plugin "bundler-multilock", "~> 1.2"
        TEMPLATE = <<~GEMFILE
          plugin "bundler-multilock", "~> 1.2"
          return unless Plugin.installed?("bundler-multilock")
          Plugin.send(:load_plugin, "bundler-multilock")
        GEMFILE
        SNIPPET = 'return unless Plugin.installed? "bundler-multilock"'

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "injects the preamble if it's only in strings, heredocs, or comments" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        # return unless Plugin.loaded?("bundler-multilock")
        TEMPLATE = <<~GEMFILE
          plugin "bundler-multilock", "~> 2.0"
          return unless Plugin.loaded?("bundler-multilock")
        GEMFILE
        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      gemfile = File.read("Gemfile")
      expect(gemfile).to include(<<~RUBY)
        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")
      RUBY
      # the template and comment are untouched
      expect(gemfile).to include(%(# return unless Plugin.loaded?("bundler-multilock")\n))
      expect(gemfile).to include(<<~RUBY)
        TEMPLATE = <<~GEMFILE
          plugin "bundler-multilock", "~> 2.0"
          return unless Plugin.loaded?("bundler-multilock")
        GEMFILE
      RUBY
    end
  end

  it "does not inject duplicate plugin load commands when you prefer single quotes" do
    gemfile = <<~RUBY
      # frozen_string_literal: true

      source 'https://rubygems.org'

      plugin 'bundler-multilock', '#{plugin_requirement}'
      return unless Plugin.loaded?('bundler-multilock')

      gem 'concurrent-ruby', '1.2.2'
    RUBY

    with_gemfile("") do
      File.write("Gemfile", gemfile)

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq gemfile
    end
  end

  it "injects the guard after an existing plugin declaration" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"

        gem "concurrent-ruby", "1.2.2"
      RUBY

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq(<<~RUBY)
        source "https://rubygems.org"

        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
    end
  end

  it "injects the guard after an existing plugin declaration in a secondary Gemfile" do
    with_gemfile("") do
      File.write("Gemfile", <<~RUBY)
        source "https://rubygems.org"

        eval_gemfile("injected.rb")
      RUBY
      File.write("injected.rb", <<~RUBY)
        plugin "bundler-multilock", "#{plugin_requirement}"

        gem "concurrent-ruby", "1.2.2"
      RUBY
      gemfile = File.read("Gemfile")

      local_path = Shellwords.escape(plugin_path)
      invoke_bundler("plugin install bundler-multilock --path=#{local_path}")

      expect(File.read("Gemfile")).to eq gemfile
      expect(File.read("injected.rb")).to eq(<<~RUBY)
        plugin "bundler-multilock", "#{plugin_requirement}"
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
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
        plugin "bundler-multilock", "#{plugin_requirement}", path: #{plugin_path.inspect}
        return unless Plugin.loaded?("bundler-multilock")

        gem "concurrent-ruby", "1.2.2"
      RUBY
      injected = File.read("injected.rb")

      invoke_bundler("install")
      expect(File.read("Gemfile")).not_to include("bundler-multilock")
      expect(File.read("injected.rb")).to eq injected
    end
  end
end

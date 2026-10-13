# frozen_string_literal: true

module Bundler
  module Multilock
    # @!visibility private
    # Keeps the preamble that loads the plugin in the Gemfile up to date:
    #
    #   plugin "bundler-multilock", "~> 2.0"
    #   return unless Plugin.loaded?("bundler-multilock")
    module Preamble
      class << self
        # @return [String] the version requirement for the plugin in the preamble
        def requirement
          version = Gem::Version.new(VERSION)
          # a prerelease doesn't satisfy `~> 2.0`, so allow later prereleases
          # (and releases) of this minor version instead
          return "~> #{version}" if version.prerelease?

          "~> #{version.segments.first}.0"
        end

        # Adds the preamble to the Gemfile, or updates an existing one
        def inject
          Bundler.ui.debug("Injecting multilock preamble")

          requirement = self.requirement
          bundle_preamble1_match = /plugin\(?\s*["']bundler-multilock["']/
          bundle_preamble1 = <<~RUBY
            plugin "bundler-multilock", "#{requirement}"
          RUBY
          bundle_preamble2 = <<~RUBY
            return unless Plugin.loaded?("bundler-multilock")
          RUBY

          builder = Bundler::Plugin::DSL.new
          # this method is called as part of the plugin loading, but @loaded_plugin_names
          # hasn't been set yet, so avoid re-entrancy issues
          plugins = Bundler::Plugin.instance_variable_get(:@loaded_plugin_names)
          original_plugins = plugins.dup
          plugins << "bundler-multilock"
          begin
            builder.eval_gemfile(Bundler.default_gemfile)
          ensure
            plugins.replace(original_plugins)
          end
          gemfile_paths = builder.instance_variable_get(:@gemfiles).to_a
          gemfiles = gemfile_paths.to_h { |path| [path, path.read] }
          originals = gemfiles.transform_values(&:dup)

          gemfiles.each_value { |contents| upgrade(contents, requirement) }

          gemfile = gemfiles[Bundler.default_gemfile.expand_path] || Bundler.default_gemfile.read

          # skip past leading comments, blank lines, and sources.
          # (\G anchors at injection_point; ^ would match any later line)
          injection_point = 0
          while injection_point < gemfile.length && gemfile.match?(/\G(?:#|\n|source)/, injection_point)
            if gemfile[injection_point] == "\n"
              injection_point += 1
            else
              injection_point = (gemfile.index("\n", injection_point) || (gemfile.length - 1)) + 1
            end
          end
          guard_match = Regexp.new(Regexp.escape(bundle_preamble2).gsub('"', %(["'])))
          guard_present = gemfiles.each_value.any? { |contents| match_in_code?(contents, guard_match) }
          # if the plugin is already declared, the guard has to go after it (in
          # whichever Gemfile it's in), so that Bundler can still find the plugin
          # while it's not loaded
          guarded_declaration = !guard_present && gemfiles.each_value.any? do |contents|
            insert_after_statement(contents, bundle_preamble1_match, bundle_preamble2)
          end
          unless guarded_declaration
            # don't append to the end of the last line. (if we got to the end, the
            # Gemfile is only comments and sources, so the preamble will be injected.)
            if injection_point == gemfile.length && !gemfile.empty? && !gemfile.end_with?("\n")
              gemfile << "\n"
              injection_point += 1
            end

            inject_specific(gemfile, gemfiles.values, injection_point, bundle_preamble2, add_newline: true)
            inject_specific(gemfile,
                            gemfiles.values,
                            injection_point,
                            bundle_preamble1,
                            match: bundle_preamble1_match,
                            add_newline: false)
          end
          gemfiles[Bundler.default_gemfile.expand_path] = gemfile

          gemfiles.each do |path, contents|
            path.write(contents) unless contents == originals[path]
          end
        end

        private

        # Bundler loads the plugin before evaluating the Gemfile, so manually
        # loading it is no longer necessary. But Bundler also pre-parses the
        # Gemfile for plugins _without_ loading them, so the rest of the Gemfile
        # needs to be skipped when the plugin isn't loaded (not just installed).
        # Also update the version requirement if it doesn't allow this version,
        # or if it still references a prerelease after a release.
        def upgrade(gemfile, requirement)
          load_plugin = /^\n?[ \t]*Plugin\.send\(:load_plugin, (["'])bundler-multilock\1\)[ \t]*\n/
          gsub_code!(gemfile, load_plugin, "Plugin") { "" }
          # normalize the guard (with or without parentheses), so that it's
          # recognized as already present
          guard = /return\ unless\ Plugin\.(?:installed|loaded)\?
                   (?:\(\s*(["'])bundler-multilock\1\s*\) # parenthesized
                   |\s+(["'])bundler-multilock\2)          # or not
                  /x
          gsub_code!(gemfile, guard, "return") do |m|
            quote = m[1] || m[2]
            "return unless Plugin.loaded?(#{quote}bundler-multilock#{quote})"
          end
          # every string argument after the name is a version constraint, until
          # options (like `source:`, or `"source" =>`) start. there may be
          # newlines and comments between them.
          constraint = /\s*,(?:\s|\#[^\n]*)*(["'])[^"'\n]*\k<-1>(?!\s*=>)/
          gsub_code!(gemfile, /^([ \t]*plugin\(?\s*(["'])bundler-multilock\2)((?:#{constraint})+)/, "plugin") do |m|
            match = m[0]
            prefix, constraints = m[1], m[3].gsub(/\#[^\n]*/, "")
            quote = constraints[/["']/]
            existing_requirement = Gem::Requirement.new(*constraints.scan(/(["'])([^"'\n]*)\1/).map(&:last))
            version = Gem::Version.new(VERSION)
            if existing_requirement.satisfied_by?(version) && (version.prerelease? || !existing_requirement.prerelease?)
              next match
            end

            "#{prefix}, #{quote}#{requirement}#{quote}"
          rescue Gem::Requirement::BadRequirementError
            match
          end
        end

        # Like String#gsub!, but skips matches whose `keyword` is inside a string,
        # heredoc, or comment, instead of actual Ruby code
        #
        # @yieldparam match [MatchData]
        def gsub_code!(source, pattern, keyword)
          non_code = non_code_ranges(source)
          result = +""
          copied_until = 0
          replaced = false
          each_match(source, pattern) do |match|
            offset = match.pre_match.bytesize + match[0].b.index(keyword)
            next if non_code.any? { |range| range.cover?(offset) }

            result << source[copied_until...match.begin(0)] << yield(match)
            copied_until = match.end(0)
            replaced = true
          end
          return unless replaced

          source.replace(result << source[copied_until..])
        end

        # Yields each match of pattern in source
        #
        # @yieldparam match [MatchData]
        def each_match(source, pattern)
          position = 0
          while (match = pattern.match(source, position))
            yield match
            # (always move forward, even after an empty match)
            position = [match.end(0), match.begin(0) + 1].max
          end
        end

        # @return [true, false] if pattern matches somewhere other than in a string, heredoc, or comment
        def match_in_code?(source, pattern)
          !code_match_offsets(source, pattern).empty?
        end

        # @return [Array<Integer>] the byte offsets of matches that aren't in a string, heredoc, or comment
        def code_match_offsets(source, pattern)
          non_code = non_code_ranges(source)
          offsets = []
          each_match(source, pattern) do |match|
            offset = match.pre_match.bytesize
            offsets << offset if non_code.none? { |range| range.cover?(offset) }
          end
          offsets
        end

        # Inserts text on the line after the first statement (in code) matching pattern
        #
        # @return [true, false] if there was such a statement
        def insert_after_statement(source, pattern, text) # rubocop:disable Naming/PredicateMethod -- not a predicate
          offset = code_match_offsets(source, pattern).first
          return false unless offset

          insertion = statement_end(source, offset)
          text = "\n#{text}" if insertion == source.bytesize && !source.end_with?("\n")
          source.insert(source.byteslice(0, insertion).length, text)
          true
        end

        # @return [Integer] the byte offset of the start of the line after the
        #   statement at offset
        def statement_end(source, offset)
          require "ripper"

          line_offsets = [0]
          source.each_line { |line| line_offsets << (line_offsets.last + line.bytesize) }

          depth = 0
          Ripper.lex(source).each do |(line, column), type, _token, state|
            start = line_offsets[line - 1] + column
            next if start < offset

            case type
            when :on_lparen, :on_lbracket, :on_lbrace then depth += 1
            when :on_rparen, :on_rbracket, :on_rbrace then depth -= 1
            when :on_nl, :on_semicolon
              return line_end(source, start) if depth.zero?
            when :on_comment
              # a comment after a complete expression ends the statement
              return line_end(source, start) if depth.zero? && state.anybits?(Ripper::EXPR_END_ANY)
            end
          end
          source.bytesize
        end

        def line_end(source, offset)
          (source.byteindex("\n", offset) || (source.bytesize - 1)) + 1
        end

        # @return [Array<Range>] the byte ranges of strings, heredocs, and comments in Ruby source
        def non_code_ranges(source)
          require "ripper"

          line_offsets = [0]
          source.each_line { |line| line_offsets << (line_offsets.last + line.bytesize) }

          Ripper.lex(source).filter_map do |(line, column), type, token|
            start = line_offsets[line - 1] + column
            case type
            when :on_tstring_content, :on_comment, :on_embdoc then start...(start + token.bytesize)
            when :on___end__ then start...source.bytesize
            end
          end
        end

        def inject_specific(gemfile, gemfiles, injection_point, preamble, add_newline:, match: nil) # rubocop:disable Naming/PredicateMethod -- not a predicate
          # allow either type of quotes
          match ||= Regexp.new(Regexp.escape(preamble).gsub('"', %(["'])))
          return false if gemfiles.any? { |g| match_in_code?(g, match) }

          add_newline = false unless gemfile[injection_point - 1] == "\n"

          gemfile.insert(injection_point, "\n") if add_newline
          gemfile.insert(injection_point, preamble)

          true
        end
      end
    end
  end
end

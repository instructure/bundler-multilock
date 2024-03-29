# frozen_string_literal: true

source "https://rubygems.org"

# Declare your gem's dependencies in broadcast_policy.gemspec.
# Bundler will treat runtime dependencies like base dependencies, and
# development dependencies will be added by default to the :development group.
gemspec

plugin "bundler-multilock", path: "."
return unless Plugin.installed?("bundler-multilock")

Plugin.send(:load_plugin, "bundler-multilock")

lockfile active: RUBY_VERSION >= "2.7" do
  gem "debug", "~> 1.9", require: false
  gem "irb", "~> 1.11", require: false
  gem "rubocop-inst", "~> 1.0", require: false
  gem "rubocop-rake", "~> 0.6", require: false
  gem "rubocop-rspec", "~> 2.24", require: false
  gem "stringio", "~> 3.1", require: false
end

lockfile "ruby-2.6", active: RUBY_VERSION < "2.7" do
  # newer versions of these gems are not compatible with Ruby > 2.6
  gem "debug", "~> 1.8.0", require: false
  gem "irb", "1.6.3", require: false
  gem "stringio", "3.0.6", require: false
end

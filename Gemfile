# frozen_string_literal: true

source "https://rubygems.org"

# Declare your gem's dependencies in broadcast_policy.gemspec.
# Bundler will treat runtime dependencies like base dependencies, and
# development dependencies will be added by default to the :development group.
gemspec

plugin "bundler-multilock", path: "."
return unless Plugin.installed?("bundler-multilock")

Plugin.send(:load_plugin, "bundler-multilock")

gem "debug", "~> 1.10", require: false
gem "rubocop", "~> 1.72", require: false
gem "rubocop-inst", "~> 1", require: false
gem "rubocop-rake", "~> 0.7", require: false
gem "rubocop-rspec", "~> 3.5", require: false

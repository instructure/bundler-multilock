# frozen_string_literal: true

source "https://rubygems.org"

# Bundler adds plugins as regular dependencies, so this also takes the place of `gemspec`
plugin "bundler-multilock", path: "."
return unless Plugin.loaded?("bundler-multilock")

gem "debug", "~> 1.10", require: false, platforms: :mri
gem "gem-release", "~> 2.2", require: false
gem "rake", "~> 13.2", require: false
gem "rspec", "~> 3.13", require: false
gem "rubocop", "~> 1.72", require: false
gem "rubocop-inst", "~> 1", require: false
gem "rubocop-rake", "~> 0.7", require: false
gem "rubocop-rspec", "~> 3.5", require: false

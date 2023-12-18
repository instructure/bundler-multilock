# frozen_string_literal: true

require_relative "lib/bundler/multilock/version"

Gem::Specification.new do |spec|
  spec.name          = "bundler-multilock"
  spec.version       = Bundler::Multilock::VERSION
  spec.authors       = ["Instructure"]
  spec.summary       = "Support Multiple Lockfiles"
  spec.homepage      = "https://github.com/instructure/bundler-multilock"
  spec.license       = "MIT"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files         = Dir.glob("lib/**/*") + %w[plugins.rb]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 2.7"

  spec.add_dependency "bundler", ">= 2.4.19", "< 2.6"

  spec.add_development_dependency "debug", "~> 1.8"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop-inst", "~> 1.0"
  spec.add_development_dependency "rubocop-rake", "~> 0.6"
  spec.add_development_dependency "rubocop-rspec", "~> 2.24"
end

# frozen_string_literal: true

require_relative "lib/bundler/multilock/version"

Gem::Specification.new do |spec|
  spec.name          = "bundler-multilock"
  spec.version       = Bundler::Multilock::VERSION
  spec.authors       = ["Instructure"]
  spec.summary       = "Support Multiple Lockfiles"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files         = Dir.glob("lib/**/*") + %w[plugins.rb]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  spec.add_dependency "bundler", ">= 2.4.19"

  spec.add_development_dependency "byebug"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop-inst"
  spec.add_development_dependency "rubocop-rake"
  spec.add_development_dependency "rubocop-rspec"
end

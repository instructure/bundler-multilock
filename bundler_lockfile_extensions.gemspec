# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "bundler_lockfile_extensions"
  spec.version       = "0.0.2"
  spec.authors       = ["Instructure"]
  spec.summary       = "Support Multiple Lockfiles"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files         = Dir.glob("{lib,spec}/**/*") + %w[plugins.rb]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.1"

  spec.add_dependency "bundler", ">= 2.3.26"

  spec.add_development_dependency "byebug"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop-inst"
  spec.add_development_dependency "rubocop-rake"
  spec.add_development_dependency "rubocop-rspec"
end

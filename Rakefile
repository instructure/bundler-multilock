# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RSpec::Core::RakeTask.new

RuboCop::RakeTask.new do |task|
  task.options = ["-S"]
end

task default: %i[spec]

# frozen_string_literal: true

require "debug" if RUBY_ENGINE == "ruby"

require_relative "support/helpers"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.max_formatted_output_length = nil
  end

  config.run_all_when_everything_filtered = true
  config.filter_run :focus
  config.order = "random"

  config.include MultilockHelpers
end

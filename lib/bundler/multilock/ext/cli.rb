# frozen_string_literal: true

module Bundler
  module Multilock
    module Ext
      module CLI
        # What we need to know from the CLI instance, when we can't find it
        Invocation = Struct.new(:current_command_chain, :options)
        private_constant :Invocation

        module ClassMethods
          def instance
            return @instance if instance_variable_defined?(:@instance)

            # this is a little icky, but there's no other way to determine which command was run
            @instance = begin
              ObjectSpace.each_object(::Bundler::CLI).first
            rescue RuntimeError
              # JRuby only supports ObjectSpace for classes and modules (unless
              # it's run with -X+O), so parse the command line the same way Thor
              # does instead
              invocation_from_argv
            end
          end

          private

          def invocation_from_argv
            # `bundle exec` loads Ruby executables (like bundler itself) in the
            # same process, with their own ARGV. ObjectSpace would find the
            # original `exec` command then, so be consistent with that. (Bundler
            # only loads CLI::Exec when running `bundle exec`.)
            return Invocation.new([:exec], {}) if ::Bundler::CLI.const_defined?(:Exec, false)

            args = ARGV.dup
            name = normalize_command_name(retrieve_command_name(args))
            command = all_commands[name]
            return unless command

            _arguments, options = Bundler::Thor::Options.split(args)
            options = Bundler::Thor::Options.new(class_options.merge(command.options)).parse(options)
            Invocation.new([name.to_sym], options)
          rescue Bundler::Thor::Error
            nil
          end
        end

        ::Bundler::CLI.extend(ClassMethods)
      end
    end
  end
end

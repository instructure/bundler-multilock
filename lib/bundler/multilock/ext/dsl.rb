# frozen_string_literal: true

#
# Copyright (C) 2023 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

require "set"

module Bundler
  module Multilock
    module Ext
      module Dsl
        module ClassMethods
          ::Bundler::Dsl.singleton_class.prepend(self)

          # Significant changes:
          #  * evaluate the prepare block as part of the gemfile
          #  * mark Multilock as loaded once the main gemfile is evaluated
          #    so that they're not loaded multiple times
          def evaluate(gemfile, lockfile, unlock)
            builder = new
            builder.eval_gemfile(gemfile, &Multilock.prepare_block) if Multilock.prepare_block
            builder.eval_gemfile(gemfile)
            Multilock.loaded!
            builder.to_definition(lockfile, unlock)
          end
        end

        ::Bundler::Dsl.prepend(self)

        def initialize
          super
          @gemfiles = Set.new
        end

        # Significant changes:
        #  * allow a block
        def eval_gemfile(gemfile, contents = nil, &block)
          expanded_gemfile_path = Pathname.new(gemfile).expand_path(@gemfile&.parent)
          original_gemfile = @gemfile
          @gemfile = expanded_gemfile_path
          @gemfiles << expanded_gemfile_path
          contents ||= Bundler.read_file(@gemfile.to_s)
          if block
            instance_eval(&block)
          else
            instance_eval(contents.dup.tap { |x| x.untaint if RUBY_VERSION < "2.7" }, gemfile.to_s, 1)
          end
        rescue Exception => e # rubocop:disable Lint/RescueException
          message = "There was an error " \
                    "#{e.is_a?(GemfileEvalError) ? "evaluating" : "parsing"} " \
                    "`#{File.basename gemfile.to_s}`: #{e.message}"

          raise Bundler::Dsl::DSLError.new(message, gemfile, e.backtrace, contents)
        ensure
          @gemfile = original_gemfile
        end

        def lockfile(*args, **kwargs, &)
          return if Multilock.loaded?

          Multilock.add_lockfile(*args, builder: self, **kwargs, &)
        end
      end
    end
  end
end
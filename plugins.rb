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

require_relative "lib/bundler/multilock"

# Registering for this event makes Bundler load the plugin before it evaluates
# the Gemfile, so `lockfile` is available without loading the plugin manually.
Bundler::Plugin.add_hook(Bundler::Plugin::Events::GEM_BEFORE_EVAL) do |_gemfile, _lockfile|
  # nothing to do; loading the plugin is all that's needed
end

Bundler::Plugin.add_hook(Bundler::Plugin::Events::GEM_AFTER_INSTALL_ALL) do |_|
  Bundler::Multilock.after_install_all
end

# Bundler::Multilock

Extends Bundler to allow arbitrarily many lockfiles (and Gemfiles!)
for variations of the Gemfile, while keeping all of the lockfiles in sync.

`bundle install`, `bundle lock`, and `bundle update` will operate only on
the default lockfile (Gemfile.lock), afterwhich all other lockfiles will
be re-created based on this default lockfile. Additional lockfiles can be
based on the same Gemfile, but vary at runtime. You can force a specific
lockfile by setting the `BUNDLE_LOCKFILE` environment variable, or customize
it any way you want by setting `default: true` on one of your lockfiles
in your Gemfile.

Alternately (or in addition!), you can define a lockfile to use a completely
different Gemfile. This will have the effect that common dependencies between
the two Gemfiles will stay locked to the same version in each lockfile.

A lockfile definition can opt in to requiring explicit pinning for
any dependency that exists in that variation, but does not exist in the default
lockfile. This is especially useful if for some reason a given
lockfile will _not_ be committed to version control (such as a variation
that will include private plugins).

Finally, `bundle check` will enforce additional checks to compare the final
locked versions of dependencies between the various lockfiles to ensure
they end up the same. This check might be tripped if Gemfile variations
(accidentally!) have conflicting version constraints on a dependency, that
are still self-consistent with that single Gemfile variation.
`bundle install`, `bundle lock`, and `bundle update` will also verify these
additional checks. You can additionally explicitly allow version variations
between explicit dependencies (and their sub-dependencies), for cases where
the lockfile variation is specifically to transition to a new version of
a dependency (like a Rails upgrade).

## Installation

Install the gem and add to the Gemfile by executing:

```bash
bundle plugin install bundler-multilock
```

## Usage

Add additional lockfiles to your Gemfile like so:

```ruby
# frozen_string_literal: true

source "https://rubygems.org"

plugin "bundler-multilock", "~> 1.0"
return unless Plugin.installed?("bundler-multilock")
Plugin.send(:load_plugin, "bundler-multilock")

lockfile "rails-6.1" do
  gem "rails", "~> 6.1"
end

lockfile "rails-7.0" do
  gem "rails", "~> 7.0"
end
```

And then run `bundle install`. This will automatically generate additional
lockfiles: `Gemfile.rails-6.1.lock` and `Gemfile.rails-7.0.lock`.

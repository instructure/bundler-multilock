# Bundler::Multilock

[![Gem Version](https://img.shields.io/gem/v/bundler-multilock)](https://rubygems.org/gems/bundler-multilock)
[![Continous Integration](https://github.com/instructure/bundler-multilock/workflows/Continuous%20Integration/badge.svg)](https://github.com/instructure/bundler-multilock/actions/workflows/ci.yml)

Extends Bundler to allow arbitrarily many lockfiles (and Gemfiles!)
for variations of the Gemfile, while keeping all of the lockfiles in sync.

`bundle install`, `bundle lock`, and `bundle update` will operate only on
the default lockfile (Gemfile.lock), afterwhich all other lockfiles will
be re-created based on this default lockfile. Additional lockfiles can be
based on the same Gemfile, but vary at runtime. You can force a specific
lockfile by setting the `BUNDLE_LOCKFILE` environment variable, or customize
it any way you want by setting `current: true` on one of your lockfiles
in your Gemfile.

Alternately (or in addition!), you can define a lockfile to use a completely
different Gemfile. This will have the effect that common dependencies between
the two Gemfiles will stay locked to the same version in each lockfile.

A lockfile definition can opt in to requiring explicit pinning for
any dependency that exists in that variation, but does not exist in the default
lockfile. This is especially useful if for some reason a given
lockfile will _not_ be committed to version control (such as a variation
that will include private gems).

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
Note that the default lockfile (`Gemfile.lock`) will not contain any gems
that are in the specific `lockfile` blocks. If you have gems you want in
the default lockfile, but not in other lockfiles, you can define a block
for just that lockfile:

```ruby
lockfile do
  gem "rake"
end
```

When running other commands (such as tests), you select the desired lockfile
with `BUNDLE_LOCKFILE`:

```shell
BUNDLE_LOCKFILE=rails-7.0 bundle exec rspec
```

You can also dynamically select it in your Gemfile, and pass `current: true`
to (exactly one!) `lockfile` method.

## Comparison to Appraisal

[Appraisal](https://github.com/thoughtbot/appraisal) is a gem that might serve
a similar purpose, but with a very different implementation. Appraisal is not
a Bundler plugin, and instead works as a separate utility automatically
generating additional gemfiles, based on the primary gemfile. It has no concern
for lockfiles at all, and any steps to ensure the gemfiles themselves stay in
sync are manual. Bundler::Multilock, in contrast, is not a separate file, does
not generate additional gemfiles, automatically keeps the additional lockfiles
synchronized anytime you run `bundle install` or `bundle update`, and ensures
that all common dependencies stay in sync in the lockfile themselves between
the lockfiles. It also supports relatively orthogonal scenarios, such as
keeping dependencies in lockfiles for multiple gems in sync.

### Upgrading from Appraisal to Bundler::Multilock

First, remove appraisal from your Gemfile or gemspec, then install
Bundler::Multilock as above. Then mv the contents of your Appraisals file into
your Gemfile, just below the the newly added lines from Bundler::Multilock.
Change the method from `appraise` to `lockfile`. Assuming you've committed
all of your lockfiles, move them from `gemfiles/*.gemfile.lock` to
`Gemfile.*.lock` next to the main Gemfile. Then run `bundle install` to
ensure everything is happy. Be sure to update any tooling that uses
`BUNDLE_GEMFILE` to use `BUNDLE_LOCKFILE` (with the appropriate changes to its
value), and remove any `appraisal install` steps, since they're now redundant.
Bundler::Multilock doesn't have a separate executable to repeat a command for
each lockfile, so you'll need to handle that yourself if you're using
something like `appraisal bundle exec rspec`.

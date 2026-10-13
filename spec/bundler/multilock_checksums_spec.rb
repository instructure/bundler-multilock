# frozen_string_literal: true

describe Bundler::Multilock do
  describe "checksums" do
    it "syncs whether there are checksums to secondary lockfiles" do
      with_gemfile(<<~RUBY) do
        gem "concurrent-ruby", "1.2.2"

        lockfile do
        end

        lockfile "alt" do
          gem "rake", "13.2.1"
        end
      RUBY
        invoke_bundler("install")
        expect(File.read("Gemfile.alt.lock")).to include("CHECKSUMS")

        # the parent lockfile has checksums, but the alternate doesn't
        remove_checksums_section("Gemfile.alt.lock")
        expect { invoke_bundler("check") }
          .to raise_error(/The parent lockfile has checksums, but Gemfile.alt.lock does not/)

        invoke_bundler("install")
        expect(File.read("Gemfile.alt.lock")).to match(/^CHECKSUMS\n.*^  rake \(13\.2\.1\) sha256=/m)
        invoke_bundler("check")

        # and the other way around
        remove_checksums_section("Gemfile.lock")
        expect { invoke_bundler("check") }
          .to raise_error(/The parent lockfile does not have checksums, but Gemfile.alt.lock does/)

        invoke_bundler("install")
        expect(File.read("Gemfile.alt.lock")).not_to include("CHECKSUMS")
        invoke_bundler("check")
      end
    end

    it "keeps checksums the same for gems in common between lockfiles" do
      with_gemfile(<<~RUBY) do
        gem "concurrent-ruby", "1.2.2"
        gem "tzinfo", "2.0.6"

        lockfile do
        end

        lockfile "alt" do
          gem "rake", "13.2.1"
        end
      RUBY
        invoke_bundler("install")
        expect(expect_matching_checksums("Gemfile.lock", "Gemfile.alt.lock"))
          .to include("concurrent-ruby (1.2.2)", "tzinfo (2.0.6)")
        # gems only in the alternate lockfile get checksums too
        expect(lockfile_checksums("Gemfile.alt.lock")["rake (13.2.1)"]).not_to be_nil

        # update a gem in common, so that the alternate lockfile gets merged
        # with the new version from the default lockfile
        replace_string("Gemfile", 'gem "concurrent-ruby", "1.2.2"', 'gem "concurrent-ruby", "1.3.4"')
        invoke_bundler("install")
        expect(File.read("Gemfile.alt.lock")).to include("concurrent-ruby (1.3.4)")
        expect(expect_matching_checksums("Gemfile.lock", "Gemfile.alt.lock"))
          .to include("concurrent-ruby (1.3.4)", "tzinfo (2.0.6)")
        expect(lockfile_checksums("Gemfile.alt.lock")["rake (13.2.1)"]).not_to be_nil
      end
    end

    it "notices and fixes mismatched checksums for gems in common between lockfiles" do
      with_gemfile(<<~RUBY) do
        gem "concurrent-ruby", "1.2.2"

        lockfile do
        end

        lockfile "alt" do
          gem "rake", "13.2.1"
        end
      RUBY
        invoke_bundler("install")

        bad_checksum = "0" * 64
        replace_string("Gemfile.alt.lock",
                       /^(  concurrent-ruby \(1\.2\.2\) sha256=)\h+$/,
                       "\\1#{bad_checksum}")
        expect(lockfile_checksums("Gemfile.alt.lock")["concurrent-ruby (1.2.2)"]).to eq bad_checksum

        expect { invoke_bundler("check") }
          .to raise_error(/The checksum for concurrent-ruby \(1\.2\.2\) in Gemfile.alt.lock does not match/)

        invoke_bundler("lock")
        expect(expect_matching_checksums("Gemfile.lock", "Gemfile.alt.lock")).to include("concurrent-ruby (1.2.2)")
        invoke_bundler("check")
      end
    end

    it "only fetches checksums it can't compute locally when not running with --local" do
      with_gemfile(<<~RUBY) do
        gem "concurrent-ruby", "1.2.2"

        lockfile do
        end

        lockfile "alt" do
          gem "rake", "13.2.1"
        end
      RUBY
        use_local_bundle_path
        invoke_bundler("install")

        # a gem only in the alternate lockfile, without a checksum or a cached
        # package to compute one from
        replace_string("Gemfile.alt.lock", /^(  rake \(13\.2\.1\)) sha256=\h+$/, "\\1")
        FileUtils.rm(Dir["#{local_gem_dir}/cache/rake-13.2.1.gem"])

        expect { invoke_bundler("install --local") }
          .to raise_error(/Could not find checksums for rake-13\.2\.1 \(for Gemfile.alt.lock\) locally/)
        expect { invoke_bundler("lock --local") }
          .to raise_error(/Could not find checksums for rake-13\.2\.1 \(for Gemfile.alt.lock\) locally/)
        expect(lockfile_checksums("Gemfile.alt.lock")["rake (13.2.1)"]).to be_nil

        invoke_bundler("lock")
        expect(lockfile_checksums("Gemfile.alt.lock")["rake (13.2.1)"]).to match(/\A\h{64}\z/)
        invoke_bundler("install --local")
      end
    end
  end
end

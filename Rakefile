# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create do |task|
  task.test_globs = ["test/devbox/**/*_test.rb"]
end

require "rubocop/rake_task"

RuboCop::RakeTask.new

namespace :integration do
  desc "Verify dnsmasq 2.93 nftset behavior in an isolated network namespace"
  task :dnsmasq_nftset do
    sh File.expand_path("test/integration/dnsmasq_nftset_test.sh", __dir__)
  end

  desc "Verify devbox-net policy with real nft and dnsmasq in an isolated namespace"
  task :net_helper_policy do
    sh File.expand_path("test/integration/net_helper_policy_test.sh", __dir__)
  end
end

task default: %i[test rubocop]

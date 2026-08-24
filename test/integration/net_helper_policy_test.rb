# frozen_string_literal: true

require "fileutils"
require "json"
require "stringio"
require "tmpdir"

require "devbox/error"
require "devbox/net_helper"

class SelectiveRunner < Devbox::NetHelper::CommandRunner
  def initialize(dnsmasq)
    super()
    @dnsmasq = dnsmasq
  end

  def run!(*command)
    return if command.first == @dnsmasq && command.none? { |argument| argument == "--test" }

    super
  end
end

class AlwaysRunning
  def running?(_pid_file, _executable)
    true
  end

  def stop(_pid_file, _executable, **); end
end

def assert!(condition, message)
  raise message unless condition
end

nft = ENV.fetch("DEVBOX_TEST_NFT")
dnsmasq = ENV.fetch("DEVBOX_TEST_DNSMASQ")
ip = ENV.fetch("DEVBOX_TEST_IP")
runner = SelectiveRunner.new(dnsmasq)

# The production module creates this dedicated account. The namespace test uses
# the ubiquitous nobody/nogroup pair while retaining the exact generated config.
Devbox::NetHelper.send(:remove_const, :DNS_USER)
Devbox::NetHelper.const_set(:DNS_USER, "nobody")
Devbox::NetHelper.send(:remove_const, :DNS_GROUP)
Devbox::NetHelper.const_set(:DNS_GROUP, "nogroup")

Dir.mktmpdir("devbox-net-policy-") do |root|
  runtime = File.join(root, "run")
  resolv = File.join(root, "resolv.conf")
  File.write(resolv, "nameserver 127.0.0.53\n")
  system = Devbox::NetHelper::SystemContext.new(
    euid: Process.euid,
    root_uid: Process.euid,
    runtime_root: runtime,
    net_root: "/sys/class/net",
    proc_root: "/proc",
    resolver_paths: [resolv]
  )
  policy = JSON.generate(
    "mode" => "allowlist",
    "allowedDomains" => ["example.com"],
    "allowedCIDRs" => ["192.168.0.0/16"],
    "allowedTCPPorts" => [80, 443],
    "allowedUDPPorts" => [53]
  )

  runner.run!(nft, "add", "table", "inet", "devbox")
  runner.run!(nft, "add", "chain", "inet", "devbox", "input_dispatch")
  runner.run!(nft, "add", "chain", "inet", "devbox", "forward_dispatch")

  helper = Devbox::NetHelper.new(
    ip_path: ip,
    nft_path: nft,
    dnsmasq_path: dnsmasq,
    env: { "SUDO_UID" => "1000" },
    stdin: StringIO.new(policy),
    runner: runner,
    system: system,
    processes: AlwaysRunning.new
  )
  helper.run(%w[apply-policy 7])
  helper.run(%w[reconcile])

  ruleset = runner.capture!(nft, "list", "table", "inet", "devbox")
  assert!(ruleset.include?("timeout 30s"), "missing bounded domain-set timeout")
  assert!(ruleset.include?("meta mark set 0x0000db01"), "missing domain allow mark")
  assert!(ruleset.include?("meta mark set 0x0000db02"), "missing explicit CIDR mark")
  assert!(ruleset.include?("meta mark set 0x0000db03"), "missing host DNS/ICMP mark")
  assert!(ruleset.include?("iifname \"devbox7\""), "missing per-slot dispatch")

  config = File.read(File.join(runtime, "7", "dnsmasq.conf"))
  assert!(config.include?("cache-size=0"), "dnsmasq cache must be disabled")
  assert!(config.include?("max-ttl=1"), "dnsmasq client TTL must be bounded")
  assert!(config.include?("server=/example.com/127.0.0.53"), "missing suffix-scoped host resolver")
  assert!(!config.include?("8.8.8.8"), "public resolver fallback is forbidden")

  off_policy = JSON.generate(JSON.parse(policy).merge("mode" => "off"))
  off_helper = Devbox::NetHelper.new(
    ip_path: ip,
    nft_path: nft,
    dnsmasq_path: dnsmasq,
    env: { "SUDO_UID" => "1000" },
    stdin: StringIO.new(off_policy),
    runner: runner,
    system: system,
    processes: AlwaysRunning.new
  )
  off_helper.run(%w[apply-policy 7])
  tightened = runner.capture!(nft, "list", "table", "inet", "devbox")
  assert!(!tightened.include?("0x0000db01"), "off policy retained normal allow mark")
  assert!(!tightened.include?("0x0000db02"), "off policy retained private allow mark")
end

puts "devbox-net policy integration test passed"

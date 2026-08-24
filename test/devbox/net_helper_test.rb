# frozen_string_literal: true

require "test_helper"
require "stringio"

class Devbox::NetHelperTest < Minitest::Test
  class RecordingRunner
    attr_reader :commands, :transactions
    attr_accessor :inventory

    def initialize(&block)
      @commands = []
      @transactions = []
      @block = block
      @inventory = { "nftables" => [] }
    end

    def run!(*command)
      @commands << command
      @transactions << File.read(command.last) if command[0, 2] == %w[/nix/store/nft --file]
      @block&.call(command)
    end

    def capture!(*command)
      @commands << command
      return JSON.generate(@inventory) if command == %w[/nix/store/nft --json list table inet devbox]

      @block&.call(command)
      ""
    end
  end

  class FakeProcesses
    attr_reader :stops
    attr_accessor :running

    def initialize(running: true)
      @running = running
      @stops = []
    end

    def running?(_pid_file, _executable)
      running.instance_of?(Array) ? running.shift : running
    end

    def stop(pid_file, executable, **options)
      @stops << [pid_file, executable, options]
    end
  end

  def around
    Dir.mktmpdir("devbox-net-") do |dir|
      @dir = dir
      @runtime_root = File.join(dir, "run")
      @net_root = File.join(dir, "net")
      @resolv_conf = File.join(dir, "resolv.conf")
      FileUtils.mkdir(@net_root)
      File.write(@resolv_conf, "nameserver 127.0.0.53\n")
      super
    end
  end

  def test_ensure_constructs_single_queue_tap_commands
    runner = RecordingRunner.new

    helper(runner: runner).run(%w[ensure 7 1])

    assert_equal [
      %w[/nix/store/ip tuntap add dev devbox7 mode tap user 1000],
      %w[/nix/store/ip addr flush dev devbox7],
      %w[/nix/store/ip addr add 10.201.7.1/30 dev devbox7],
      %w[/nix/store/ip link set dev devbox7 group 201],
      %w[/nix/store/ip link set dev devbox7 up]
    ], runner.commands
  end

  def test_process_manager_recognizes_managed_dnsmasq_across_store_generations
    proc_root = File.join(@dir, "proc")
    process_dir = File.join(proc_root, "4242")
    old_dnsmasq = File.join(@dir, "old-generation", "bin", "dnsmasq")
    new_dnsmasq = File.join(@dir, "new-generation", "bin", "dnsmasq")
    slot_dir = File.join(@runtime_root, "7")
    FileUtils.mkdir_p([process_dir, File.dirname(old_dnsmasq), File.dirname(new_dnsmasq), slot_dir])
    File.write(old_dnsmasq, "")
    File.write(new_dnsmasq, "")
    File.symlink(old_dnsmasq, File.join(process_dir, "exe"))
    File.binwrite(
      File.join(process_dir, "cmdline"),
      "#{old_dnsmasq}\0--conf-file=#{slot_dir}/dnsmasq-old.conf.candidate\0"
    )
    manager = Devbox::NetHelper::ProcessManager.new(proc_root: proc_root)

    assert manager.send(:expected_process?, 4242, new_dnsmasq, slot_dir)
    assert_equal [4242], manager.send(:managed_pids, slot_dir)

    File.binwrite(File.join(process_dir, "cmdline"), "#{old_dnsmasq}\0--conf-file=/tmp/unmanaged.conf\0")
    refute manager.send(:expected_process?, 4242, new_dnsmasq, slot_dir)
    assert_empty manager.send(:managed_pids, slot_dir)
  end

  def test_ensure_uses_multi_queue_and_does_not_recreate_existing_tap
    FileUtils.mkdir(File.join(@net_root, "devbox255"))
    runner = RecordingRunner.new

    helper(runner: runner).run(%w[ensure 255 2])

    refute(runner.commands.any? { |command| command.include?("tuntap") })
    assert_equal %w[/nix/store/ip addr flush dev devbox255], runner.commands.first
  end

  def test_ensure_adds_multi_queue_when_creating_tap
    runner = RecordingRunner.new

    helper(runner: runner).run(%w[ensure 0 256])

    assert_equal %w[/nix/store/ip tuntap add dev devbox0 mode tap user 1000 multi_queue], runner.commands.first
  end

  def test_delete_only_deletes_an_existing_derived_tap
    runner = RecordingRunner.new
    helper(runner: runner).run(%w[delete 9])
    refute(runner.commands.any? { |command| command.first == "/nix/store/ip" })

    FileUtils.mkdir(File.join(@net_root, "devbox9"))
    helper(runner: runner).run(%w[delete 9])
    ip_commands = runner.commands.select { |command| command.first == "/nix/store/ip" }
    assert_equal [%w[/nix/store/ip link delete dev devbox9]], ip_commands
  end

  def test_repeated_ensure_and_delete_are_idempotent
    tap = File.join(@net_root, "devbox4")
    runner = RecordingRunner.new do |command|
      FileUtils.mkdir(tap) if command[1, 2] == %w[tuntap add]
      FileUtils.rmdir(tap) if command[1, 2] == %w[link delete]
    end
    instance = helper(runner: runner)

    2.times { instance.run(%w[ensure 4 1]) }
    create_count = runner.commands.count { |command| command[1, 2] == %w[tuntap add] }
    assert_equal 1, create_count

    2.times { instance.run(%w[delete 4]) }
    delete_count = runner.commands.count { |command| command[1, 2] == %w[link delete] }
    assert_equal 1, delete_count
  end

  def test_rejects_hostile_and_out_of_range_arguments
    runner = RecordingRunner.new
    invalid = [
      %w[ensure -1 1], %w[ensure 256 1], %w[ensure 1 0], %w[ensure 1 257],
      %w[ensure 1x 1], %w[ensure 01 1], %w[ensure 1 1 extra], %w[delete 1 extra],
      ["ensure", "1; touch /tmp/pwned", "1"], %w[unknown 1]
    ]

    invalid.each do |argv|
      assert_raises(Devbox::Error, "accepted #{argv.inspect}") { helper(runner: runner).run(argv) }
    end
    assert_empty runner.commands
  end

  def test_rejects_missing_invalid_or_root_sudo_uid
    [nil, "", "0", "-1", "1000x", "01", ((2**32) - 1).to_s].each do |uid|
      env = uid.nil? ? {} : { "SUDO_UID" => uid }
      error = assert_raises(Devbox::Error) { helper(env: env).run(%w[delete 1]) }
      assert_match(/SUDO_UID/, error.message)
    end
  end

  def test_rejects_non_root_execution
    error = assert_raises(Devbox::Error) { helper(euid: 1000).run(%w[delete 1]) }

    assert_match(/must run as root/, error.message)
  end

  def test_rejects_relative_ip_path
    error = assert_raises(Devbox::Error) { helper(ip_path: "ip") }

    assert_match(/absolute/, error.message)
    assert_raises(Devbox::Error) { helper(nft_path: "nft") }
    assert_raises(Devbox::Error) { helper(dnsmasq_path: "dnsmasq") }
  end

  def test_apply_policy_materializes_allowlist_dns_and_nft_contract
    runner = RecordingRunner.new
    policy = policy_json(
      "allowedDomains" => ["GitHub.COM", "*.invalid.example"],
      "allowedCIDRs" => ["192.168.4.23/24"],
      "allowedTCPPorts" => [443, 80, 443],
      "allowedUDPPorts" => [53]
    )

    error = assert_raises(Devbox::Error) do
      helper(runner: runner, stdin: StringIO.new(policy)).run(%w[apply-policy 7])
    end
    assert_match(/invalid domain/, error.message)
    assert_empty runner.commands

    policy = policy_json(
      "allowedDomains" => ["GitHub.COM"],
      "allowedCIDRs" => ["192.168.4.23/24"],
      "allowedTCPPorts" => [443, 80, 443],
      "allowedUDPPorts" => [53]
    )
    helper(runner: runner, stdin: StringIO.new(policy)).run(%w[apply-policy 7])

    persisted = JSON.parse(File.read(File.join(@runtime_root, "7", "policy.json")))
    assert_equal ["github.com"], persisted.fetch("allowedDomains")
    assert_equal ["192.168.4.0/24"], persisted.fetch("allowedCIDRs")
    assert_equal [80, 443], persisted.fetch("allowedTCPPorts")

    config = File.read(File.join(@runtime_root, "7", "dnsmasq.conf"))
    assert_includes config, "cache-size=0\n"
    assert_includes config, "max-ttl=1\n"
    assert_includes config, "listen-address=10.201.7.1\n"
    assert_includes config, "server=/github.com/127.0.0.53\n"
    assert_match(%r{nftset=/github\.com/4#inet#devbox#db_slot_set_7_[0-9a-f]{12}_domains}, config)
    refute_includes config, "server=127.0.0.53\n"

    transaction = runner.transactions.fetch(0)
    assert_match(/timeout 30s/, transaction)
    assert_match(/ip daddr @db_slot_set_7_.* tcp dport \{ 80, 443 \} meta mark set 0x0000db01/, transaction)
    assert_match(%r{ip daddr \{ 192\.168\.4\.0/24 \}.*meta mark set 0x0000db02}, transaction)
    assert_includes transaction, "ip saddr 10.201.7.2 ip daddr 10.201.7.1 udp dport 53 meta mark set 0x0000db03"
  end

  def test_open_and_off_policies_have_distinct_forwarding_rules
    runner = RecordingRunner.new
    open = policy_json("mode" => "open", "allowedCIDRs" => ["10.10.0.0/16"])
    helper(runner: runner, stdin: StringIO.new(open)).run(%w[apply-policy 1])
    open_transaction = runner.transactions.last
    assert_match(/forward.*meta mark set 0x0000db01/, open_transaction)
    assert_match(%r{10\.10\.0\.0/16.*meta mark set 0x0000db02}, open_transaction)
    assert_includes File.read(File.join(@runtime_root, "1", "dnsmasq.conf")), "server=127.0.0.53"

    off = policy_json("mode" => "off")
    helper(runner: runner, stdin: StringIO.new(off)).run(%w[apply-policy 1])
    off_transaction = runner.transactions.last
    refute_match(/forward.*meta mark set 0x0000db0[12]/, off_transaction)
    refute_includes File.read(File.join(@runtime_root, "1", "dnsmasq.conf")), "server="
  end

  def test_policy_validation_is_strict_and_does_not_run_commands
    invalid = [
      "not json",
      JSON.generate([]),
      policy_json("mode" => "anything"),
      policy_json("allowedDomains" => ["bad/domain"]),
      policy_json("allowedCIDRs" => ["2001:db8::/32"]),
      policy_json("allowedTCPPorts" => [0]),
      policy_json("allowedUDPPorts" => ["53"]),
      "{\"mode\":\"off\",\"mode\":\"open\",\"allowedDomains\":[]," \
      "\"allowedCIDRs\":[],\"allowedTCPPorts\":[],\"allowedUDPPorts\":[]}",
      JSON.generate(JSON.parse(policy_json).merge("extra" => true))
    ]

    invalid.each do |source|
      runner = RecordingRunner.new
      assert_raises(Devbox::Error, source) do
        helper(runner: runner, stdin: StringIO.new(source)).run(%w[apply-policy 2])
      end
      assert_empty runner.commands
    end
  end

  def test_dnsmasq_failure_restores_previous_nft_policy_and_does_not_persist_candidate
    runner = RecordingRunner.new
    processes = FakeProcesses.new(running: false)

    error = assert_raises(Devbox::Error) do
      helper(
        runner: runner,
        processes: processes,
        stdin: StringIO.new(policy_json)
      ).run(%w[apply-policy 3])
    end

    assert_match(/did not remain running/, error.message)
    assert_equal 2, runner.transactions.length
    refute File.exist?(File.join(@runtime_root, "3", "policy.json"))
    assert_equal "flush chain inet devbox input_dispatch\n" \
                 "flush chain inet devbox forward_dispatch\n", runner.transactions.last
  end

  def test_failed_policy_change_restores_previous_dns_config_policy_and_nft_generation
    runner = RecordingRunner.new
    processes = FakeProcesses.new
    original = policy_json("allowedDomains" => ["old.example"])
    helper(
      runner: runner,
      processes: processes,
      stdin: StringIO.new(original)
    ).run(%w[apply-policy 3])
    original_config = File.read(File.join(@runtime_root, "3", "dnsmasq.conf"))
    original_set = original_config[/db_slot_set_3_[0-9a-f]{12}_domains/]
    processes.running = [false, true]

    error = assert_raises(Devbox::Error) do
      helper(
        runner: runner,
        processes: processes,
        stdin: StringIO.new(policy_json("allowedDomains" => ["new.example"]))
      ).run(%w[apply-policy 3])
    end

    assert_match(/did not remain running/, error.message)
    persisted = JSON.parse(File.read(File.join(@runtime_root, "3", "policy.json")))
    assert_equal ["old.example"], persisted.fetch("allowedDomains")
    assert_equal original_config, File.read(File.join(@runtime_root, "3", "dnsmasq.conf"))
    assert_includes runner.transactions.last, "add set inet devbox #{original_set}"
  end

  def test_reconcile_recreates_saved_policy_and_restarts_dnsmasq
    runner = RecordingRunner.new
    processes = FakeProcesses.new
    helper(
      runner: runner,
      processes: processes,
      stdin: StringIO.new(policy_json)
    ).run(%w[apply-policy 4])
    runner.commands.clear
    runner.transactions.clear

    helper(runner: runner, processes: processes).run(%w[reconcile])

    assert_equal 1, runner.transactions.length
    assert_match(/iifname "devbox4" jump db_slot_chain_4_/, runner.transactions.first)
    assert_equal "/nix/store/dnsmasq", processes.stops.last[1]
    assert_equal File.join(@runtime_root, "4"), processes.stops.last[2].fetch(:managed_config_dir)
  end

  def test_reconcile_dns_failure_flushes_dynamic_policy_but_keeps_saved_policy
    runner = RecordingRunner.new
    processes = FakeProcesses.new
    helper(
      runner: runner,
      processes: processes,
      stdin: StringIO.new(policy_json)
    ).run(%w[apply-policy 4])
    processes.running = false

    error = assert_raises(Devbox::Error) do
      helper(runner: runner, processes: processes).run(%w[reconcile])
    end

    assert_match(/could not reconcile/, error.message)
    assert_equal "flush chain inet devbox input_dispatch\n" \
                 "flush chain inet devbox forward_dispatch\n", runner.transactions.last
    assert File.file?(File.join(@runtime_root, "4", "policy.json"))
  end

  def test_delete_removes_policy_dns_files_and_dynamic_nft_state_before_tap
    runner = RecordingRunner.new
    processes = FakeProcesses.new
    helper(
      runner: runner,
      processes: processes,
      stdin: StringIO.new(policy_json)
    ).run(%w[apply-policy 5])
    FileUtils.mkdir(File.join(@net_root, "devbox5"))

    helper(runner: runner, processes: processes).run(%w[delete 5])

    refute File.exist?(File.join(@runtime_root, "5"))
    assert_equal "flush chain inet devbox input_dispatch\n" \
                 "flush chain inet devbox forward_dispatch\n", runner.transactions.last
    assert_equal %w[/nix/store/ip link delete dev devbox5], runner.commands.last
  end

  def test_nft_inventory_only_deletes_valid_helper_owned_objects
    runner = RecordingRunner.new
    runner.inventory = {
      "nftables" => [
        { "chain" => { "name" => "db_slot_chain_9_012345abcdef_input" } },
        { "set" => { "name" => "db_slot_set_9_012345abcdef_domains" } },
        { "chain" => { "name" => "forward" } },
        { "set" => { "name" => "user_data" } }
      ]
    }

    helper(runner: runner, stdin: StringIO.new(policy_json)).run(%w[apply-policy 9])

    transaction = runner.transactions.first
    assert_includes transaction, "delete chain inet devbox db_slot_chain_9_012345abcdef_input"
    assert_includes transaction, "delete set inet devbox db_slot_set_9_012345abcdef_domains"
    refute_includes transaction, "delete chain inet devbox forward\n"
    refute_includes transaction, "user_data"
  end

  def test_reconcile_without_saved_policy_removes_orphaned_dynamic_objects
    runner = RecordingRunner.new
    runner.inventory = {
      "nftables" => [
        { "chain" => { "name" => "db_slot_chain_8_012345abcdef_forward" } },
        { "set" => { "name" => "db_slot_set_8_012345abcdef_domains" } }
      ]
    }

    helper(runner: runner).run(%w[reconcile])

    transaction = runner.transactions.fetch(0)
    assert_includes transaction, "delete chain inet devbox db_slot_chain_8_012345abcdef_forward"
    assert_includes transaction, "delete set inet devbox db_slot_set_8_012345abcdef_domains"
    refute_match(/add rule inet devbox .*devbox8/, transaction)
  end

  def test_rejects_unsafe_preexisting_runtime_directory
    Dir.mkdir(@runtime_root)
    File.chmod(0o777, @runtime_root)

    error = assert_raises(Devbox::Error) { helper.run(%w[delete 1]) }

    assert_match(/unsafe runtime directory/, error.message)
  end

  def test_serializes_operations
    active = 0
    maximum = 0
    mutex = Mutex.new
    runner = RecordingRunner.new do
      mutex.synchronize do
        active += 1
        maximum = [maximum, active].max
      end
      sleep 0.01
      mutex.synchronize { active -= 1 }
    end
    helpers = 2.times.map { helper(runner: runner) }

    threads = helpers.map { |instance| Thread.new { instance.run(%w[ensure 3 1]) } }
    threads.each(&:join)

    assert_equal 1, maximum
  end

  private

  # Test dependencies are individually injectable so each privileged side effect can be asserted.
  # rubocop:disable Metrics/ParameterLists
  def helper(
    ip_path: "/nix/store/ip",
    nft_path: "/nix/store/nft",
    dnsmasq_path: "/nix/store/dnsmasq",
    env: { "SUDO_UID" => "1000" },
    stdin: StringIO.new,
    runner: RecordingRunner.new,
    processes: FakeProcesses.new,
    euid: 0
  )
    system = Devbox::NetHelper::SystemContext.new(
      euid: euid,
      root_uid: Process.euid,
      runtime_root: @runtime_root,
      net_root: @net_root,
      proc_root: File.join(@dir, "proc"),
      resolver_paths: [@resolv_conf]
    )
    Devbox::NetHelper.new(
      ip_path: ip_path,
      nft_path: nft_path,
      dnsmasq_path: dnsmasq_path,
      env: env,
      stdin: stdin,
      runner: runner,
      system: system,
      processes: processes
    )
  end
  # rubocop:enable Metrics/ParameterLists

  def policy_json(overrides = {})
    JSON.generate({
      "mode" => "allowlist",
      "allowedDomains" => ["example.com"],
      "allowedCIDRs" => [],
      "allowedTCPPorts" => [80, 443],
      "allowedUDPPorts" => []
    }.merge(overrides))
  end
end

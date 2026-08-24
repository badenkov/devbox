# frozen_string_literal: true

require "digest"
require "fileutils"
require "ipaddr"
require "json"
require "open3"
require "tempfile"

require_relative "error"

module Devbox
  class NetHelper
    MAX_SLOT = 255
    MAX_QUEUES = 256
    MAX_UID = (2**32) - 2
    MAX_POLICY_BYTES = 64 * 1024
    TAP_GROUP = 201
    NETWORK_PREFIX = 201
    DOMAIN_SET_TIMEOUT = 30
    ALLOW_MARK = "0x0000db01"
    PRIVATE_ALLOW_MARK = "0x0000db02"
    HOST_ALLOW_MARK = "0x0000db03"
    DNS_USER = "devbox-dns"
    DNS_GROUP = "devbox-dns"
    POLICY_KEYS = %w[mode allowedDomains allowedCIDRs allowedTCPPorts allowedUDPPorts].freeze
    MODES = %w[off allowlist open].freeze
    DOMAIN_PATTERN = /\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/
    DYNAMIC_NAME_PATTERN = /\Adb_slot_(?:chain|set)_\d+_[0-9a-f]{12}(?:_(?:input|forward|domains))?\z/

    class DuplicateRejectingHash < Hash
      def []=(key, value)
        raise Error, "duplicate network policy key: #{key.inspect}" if key?(key)

        super
      end

      alias store []=
    end

    SystemContext = Struct.new(
      :euid,
      :root_uid,
      :runtime_root,
      :net_root,
      :proc_root,
      :resolver_paths,
      keyword_init: true
    )

    class CommandRunner
      def run!(*command)
        capture!(*command)
        nil
      end

      def capture!(*command)
        stdout, stderr, status = Open3.capture3(
          { "LC_ALL" => "C" },
          *command,
          unsetenv_others: true
        )
        return stdout if status.success?

        detail = [stderr, stdout].map(&:strip).reject(&:empty?).join("\n")
        detail = "exit #{status.exitstatus}" if detail.empty?
        raise Error, "#{command.join(" ")} failed: #{detail}"
      end
    end

    class ProcessManager
      def initialize(proc_root: "/proc")
        @proc_root = proc_root
      end

      def stop(pid_file, executable, managed_config_dir: nil)
        pids = [read_pid(pid_file)]
        pids.concat(managed_pids(managed_config_dir)) if managed_config_dir
        pids.compact.uniq.each { |pid| stop_process(pid, executable, managed_config_dir) }
      ensure
        FileUtils.rm_f(pid_file)
      end

      def running?(pid_file, executable)
        pid = read_pid(pid_file)
        pid && expected_process?(pid, executable)
      end

      private

      def stop_process(pid, executable, managed_config_dir)
        return unless expected_process?(pid, executable, managed_config_dir)

        Process.kill("TERM", pid)
        40.times do
          return unless expected_process?(pid, executable, managed_config_dir)

          sleep 0.05
        end
        Process.kill("KILL", pid) if expected_process?(pid, executable, managed_config_dir)
      rescue Errno::ESRCH
        nil
      end

      def managed_pids(config_dir)
        Dir.children(@proc_root).filter_map do |entry|
          next unless /\A[1-9]\d*\z/.match?(entry)

          pid = Integer(entry, 10)
          pid if managed_dnsmasq?(pid, config_dir)
        end
      rescue Errno::ENOENT, Errno::EACCES
        []
      end

      def read_pid(path)
        return unless File.file?(path)

        value = File.read(path).strip
        pid = Integer(value, 10)
        return unless pid > 1 && pid.to_s == value

        pid
      rescue ArgumentError, Errno::ENOENT
        nil
      end

      def expected_process?(pid, executable, managed_config_dir = nil)
        actual = File.realpath(File.join(@proc_root, pid.to_s, "exe"))
        actual == File.realpath(executable) ||
          (managed_config_dir && managed_dnsmasq?(pid, managed_config_dir, actual: actual))
      rescue Errno::ENOENT, Errno::EACCES
        false
      end

      def managed_dnsmasq?(pid, config_dir, actual: nil)
        actual ||= File.realpath(File.join(@proc_root, pid.to_s, "exe"))
        return false unless File.basename(actual) == "dnsmasq"

        prefix = "#{File.expand_path(config_dir)}/"
        arguments = File.binread(File.join(@proc_root, pid.to_s, "cmdline")).split("\0")
        arguments.any? do |argument|
          next false unless argument.start_with?("--conf-file=#{prefix}")

          File.basename(argument.delete_prefix("--conf-file=")).match?(/\Adnsmasq-.+\.conf\.candidate\z/)
        end
      rescue Errno::ENOENT, Errno::EACCES
        false
      end
    end

    Policy = Struct.new(:slot, :mode, :domains, :cidrs, :tcp_ports, :udp_ports, keyword_init: true) do
      def canonical
        {
          "mode" => mode,
          "allowedDomains" => domains,
          "allowedCIDRs" => cidrs,
          "allowedTCPPorts" => tcp_ports,
          "allowedUDPPorts" => udp_ports
        }
      end

      def generation
        Digest::SHA256.hexdigest(JSON.generate(canonical))[0, 12]
      end

      def input_chain
        "db_slot_chain_#{slot}_#{generation}_input"
      end

      def forward_chain
        "db_slot_chain_#{slot}_#{generation}_forward"
      end

      def domain_set
        "db_slot_set_#{slot}_#{generation}_domains"
      end
    end

    # The executable paths and injectable system adapters are intentionally explicit here.
    # rubocop:disable Metrics/ParameterLists
    def initialize(
      ip_path:,
      nft_path:,
      dnsmasq_path:,
      env: ENV,
      stdin: $stdin,
      runner: CommandRunner.new,
      system: default_system_context,
      processes: nil
    )
      { "ip" => ip_path, "nft" => nft_path, "dnsmasq" => dnsmasq_path }.each do |label, path|
        raise Error, "#{label} path must be absolute" unless path.start_with?(File::SEPARATOR)
      end

      @ip_path = ip_path
      @nft_path = nft_path
      @dnsmasq_path = dnsmasq_path
      @env = env
      @stdin = stdin
      @runner = runner
      @system = system
      @processes = processes || ProcessManager.new(proc_root: @system.proc_root)
    end
    # rubocop:enable Metrics/ParameterLists

    def run(argv)
      command, *arguments = argv
      case command
      when "ensure"
        require_arity!(command, arguments, 2)
        slot = integer!(arguments[0], "slot", 0..MAX_SLOT)
        queues = integer!(arguments[1], "queues", 1..MAX_QUEUES)
        with_lock { ensure_tap(slot, queues, owner_uid!) }
      when "apply-policy"
        require_arity!(command, arguments, 1)
        slot = integer!(arguments[0], "slot", 0..MAX_SLOT)
        owner_uid!
        policy = parse_policy(read_policy_input, slot)
        with_lock { apply_policy(policy) }
      when "reconcile"
        require_arity!(command, arguments, 0)
        owner_uid!
        with_lock { reconcile }
      when "delete"
        require_arity!(command, arguments, 1)
        slot = integer!(arguments[0], "slot", 0..MAX_SLOT)
        owner_uid!
        with_lock { delete_slot(slot) }
      else
        raise Error, usage
      end
    end

    private

    def ensure_tap(slot, queues, owner)
      tap = tap_name(slot)
      unless tap_exists?(tap)
        command = [@ip_path, "tuntap", "add", "dev", tap, "mode", "tap", "user", owner.to_s]
        command << "multi_queue" if queues > 1
        @runner.run!(*command)
      end
      @runner.run!(@ip_path, "addr", "flush", "dev", tap)
      @runner.run!(@ip_path, "addr", "add", host_cidr(slot), "dev", tap)
      @runner.run!(@ip_path, "link", "set", "dev", tap, "group", TAP_GROUP.to_s)
      @runner.run!(@ip_path, "link", "set", "dev", tap, "up")
    end

    def apply_policy(policy)
      old_policies = load_policies
      new_policies = old_policies.reject { |current| current.slot == policy.slot } << policy
      candidate = write_candidate_config(policy)
      begin
        test_dnsmasq!(candidate)
        materialize_nft!(new_policies)

        begin
          stop_dnsmasq(policy.slot)
          start_dnsmasq!(policy, candidate)
          persist_policy(policy, candidate)
        rescue StandardError => e
          rollback_errors = rollback_policy(old_policies, policy.slot)
          detail = rollback_errors.empty? ? nil : "; rollback failed: #{rollback_errors.join("; ")}"
          raise Error, "could not apply network policy for slot #{policy.slot}: #{e.message}#{detail}"
        end
      ensure
        FileUtils.rm_f(candidate)
      end
    end

    def reconcile
      policies = load_policies
      candidates = policies.to_h { |policy| [policy.slot, write_candidate_config(policy)] }
      begin
        candidates.each_value { |path| test_dnsmasq!(path) }
        materialize_nft!(policies)

        begin
          policies.each do |policy|
            stop_dnsmasq(policy.slot)
            start_dnsmasq!(policy, candidates.fetch(policy.slot))
            replace_config(policy.slot, candidates.fetch(policy.slot))
          end
        rescue StandardError => e
          fail_closed_errors = []
          policies.each { |policy| stop_dnsmasq(policy.slot) }
          attempt(fail_closed_errors) { materialize_nft!([]) }
          raise Error, "could not reconcile network policy: #{e.message}#{format_errors(fail_closed_errors)}"
        end
      ensure
        candidates.each_value { |path| FileUtils.rm_f(path) }
      end
    end

    def delete_slot(slot)
      old_policies = load_policies
      new_policies = old_policies.reject { |policy| policy.slot == slot }
      materialize_nft!(new_policies)
      stop_dnsmasq(slot)
      remove_slot_files(slot)
      delete_tap(slot)
    end

    def rollback_policy(old_policies, slot)
      errors = []
      attempt(errors) { materialize_nft!(old_policies) }
      stop_dnsmasq(slot)
      previous = old_policies.find { |policy| policy.slot == slot }
      if previous
        candidate = write_candidate_config(previous)
        begin
          test_dnsmasq!(candidate)
          start_dnsmasq!(previous, candidate)
          replace_config(slot, candidate)
        rescue StandardError => e
          errors << e.message
        ensure
          FileUtils.rm_f(candidate)
        end
      end
      errors
    end

    def attempt(errors)
      yield
    rescue StandardError => e
      errors << e.message
    end

    def format_errors(errors)
      errors.empty? ? "" : "; fail-closed cleanup failed: #{errors.join("; ")}"
    end

    def materialize_nft!(policies)
      inventory = nft_inventory
      lines = [
        "flush chain inet devbox input_dispatch",
        "flush chain inet devbox forward_dispatch"
      ]
      inventory.fetch(:chains).each { |name| lines << "delete chain inet devbox #{name}" }
      inventory.fetch(:sets).each { |name| lines << "delete set inet devbox #{name}" }
      policies.sort_by(&:slot).each { |policy| lines.concat(nft_policy_lines(policy)) }
      run_nft_transaction(lines)
    end

    def nft_inventory
      document = JSON.parse(@runner.capture!(@nft_path, "--json", "list", "table", "inet", "devbox"))
      entries = document.fetch("nftables")
      inventory = { chains: [], sets: [] }
      entries.each do |entry|
        { "chain" => :chains, "set" => :sets }.each do |type, bucket|
          name = entry.dig(type, "name")
          inventory.fetch(bucket) << name if name&.match?(DYNAMIC_NAME_PATTERN)
        end
      end
      inventory
    rescue JSON::ParserError, KeyError, TypeError => e
      raise Error, "invalid nftables inventory: #{e.message}"
    end

    def nft_policy_lines(policy)
      tap = tap_name(policy.slot)
      host = host_ip(policy.slot)
      guest = guest_ip(policy.slot)
      lines = []
      if policy.domains.any?
        lines << "add set inet devbox #{policy.domain_set} { type ipv4_addr; flags timeout; " \
                 "timeout #{DOMAIN_SET_TIMEOUT}s; }"
      end
      lines.push(
        "add chain inet devbox #{policy.input_chain}",
        "add chain inet devbox #{policy.forward_chain}",
        "add rule inet devbox #{policy.input_chain} iifname \"#{tap}\" ip saddr #{guest} " \
        "ip daddr #{host} udp dport 53 meta mark set #{HOST_ALLOW_MARK}",
        "add rule inet devbox #{policy.input_chain} iifname \"#{tap}\" ip saddr #{guest} " \
        "ip daddr #{host} tcp dport 53 meta mark set #{HOST_ALLOW_MARK}",
        "add rule inet devbox #{policy.input_chain} iifname \"#{tap}\" ip saddr #{guest} " \
        "ip daddr #{host} ip protocol icmp meta mark set #{HOST_ALLOW_MARK}"
      )
      lines.concat(forward_policy_lines(policy, tap, guest))
      lines << "add rule inet devbox input_dispatch iifname \"#{tap}\" jump #{policy.input_chain}"
      lines << "add rule inet devbox forward_dispatch iifname \"#{tap}\" jump #{policy.forward_chain}"
      lines
    end

    def forward_policy_lines(policy, tap, guest)
      prefix = "add rule inet devbox #{policy.forward_chain} iifname \"#{tap}\" ip saddr #{guest}"
      return [] if policy.mode == "off"

      if policy.mode == "open"
        lines = ["#{prefix} meta mark set #{ALLOW_MARK}"]
        lines << "#{prefix} ip daddr #{nft_set(policy.cidrs)} meta mark set #{PRIVATE_ALLOW_MARK}" if policy.cidrs.any?
        return lines
      end

      lines = []
      { "tcp" => policy.tcp_ports, "udp" => policy.udp_ports }.each do |protocol, ports|
        next if ports.empty?

        port_match = "#{protocol} dport #{nft_set(ports)}"
        if policy.domains.any?
          lines << "#{prefix} ip daddr @#{policy.domain_set} #{port_match} meta mark set #{ALLOW_MARK}"
        end
        if policy.cidrs.any?
          lines << "#{prefix} ip daddr #{nft_set(policy.cidrs)} #{port_match} " \
                   "meta mark set #{PRIVATE_ALLOW_MARK}"
        end
      end
      lines
    end

    def nft_set(values)
      "{ #{values.join(", ")} }"
    end

    def run_nft_transaction(lines)
      Tempfile.create(["nft-", ".nft"], @system.runtime_root, mode: 0o600) do |file|
        file.write(lines.join("\n"))
        file.write("\n")
        file.flush
        @runner.run!(@nft_path, "--file", file.path)
      end
    end

    def write_candidate_config(policy)
      directory = ensure_slot_directory!(policy.slot)
      Tempfile.create(["dnsmasq-", ".conf"], directory, mode: 0o600) do |file|
        file.write(dnsmasq_config(policy))
        file.flush
        path = "#{file.path}.candidate"
        File.rename(file.path, path)
        return path
      end
    end

    def dnsmasq_config(policy)
      lines = [
        "port=53",
        "listen-address=#{host_ip(policy.slot)}",
        "bind-interfaces",
        "no-hosts",
        "no-resolv",
        "cache-size=0",
        "max-ttl=1",
        "user=#{DNS_USER}",
        "group=#{DNS_GROUP}",
        "pid-file=#{pid_file(policy.slot)}",
        "log-facility=#{log_file(policy.slot)}"
      ]
      if policy.mode == "open"
        host_resolvers.each { |resolver| lines << "server=#{resolver}" }
      elsif policy.mode == "allowlist"
        policy.domains.each do |domain|
          host_resolvers.each { |resolver| lines << "server=/#{domain}/#{resolver}" }
          lines << "nftset=/#{domain}/4#inet#devbox##{policy.domain_set}"
        end
      end
      "#{lines.join("\n")}\n"
    end

    def host_resolvers
      @system.resolver_paths.each do |path|
        next unless File.file?(path)

        resolvers = File.readlines(path, chomp: true).filter_map do |line|
          match = /\A\s*nameserver\s+([^\s#]+)(?:\s+#.*)?\z/.match(line)
          next unless match

          IPAddr.new(match[1]).to_s
        rescue IPAddr::InvalidAddressError
          nil
        end
        return resolvers.uniq unless resolvers.empty?
      end
      raise Error, "host resolver has no valid nameserver"
    end

    def test_dnsmasq!(config)
      @runner.run!(@dnsmasq_path, "--test", "--conf-file=#{config}")
    end

    def start_dnsmasq!(policy, config)
      FileUtils.rm_f(pid_file(policy.slot))
      @runner.run!(@dnsmasq_path, "--conf-file=#{config}")
      return if @processes.running?(pid_file(policy.slot), @dnsmasq_path)

      raise Error, "dnsmasq did not remain running for slot #{policy.slot}"
    end

    def stop_dnsmasq(slot)
      @processes.stop(pid_file(slot), @dnsmasq_path, managed_config_dir: slot_directory(slot))
    end

    def persist_policy(policy, candidate)
      directory = ensure_slot_directory!(policy.slot)
      replace_config(policy.slot, candidate)
      atomic_write(File.join(directory, "policy.json"), "#{JSON.pretty_generate(policy.canonical)}\n")
    end

    def replace_config(slot, candidate)
      destination = config_file(slot)
      File.rename(candidate, destination)
      File.chmod(0o600, destination)
    end

    def load_policies
      return [] unless File.directory?(@system.runtime_root)

      Dir.children(@system.runtime_root).filter_map do |entry|
        next unless /\A(?:0|[1-9]\d{0,2})\z/.match?(entry)

        slot = Integer(entry, 10)
        next unless slot.between?(0, MAX_SLOT)

        path = File.join(@system.runtime_root, entry, "policy.json")
        next unless File.file?(path)

        parse_policy(File.read(path, MAX_POLICY_BYTES + 1), slot)
      end.sort_by(&:slot)
    end

    def parse_policy(source, slot)
      raise Error, "network policy exceeds #{MAX_POLICY_BYTES} bytes" if source.bytesize > MAX_POLICY_BYTES

      data = JSON.parse(source, object_class: DuplicateRejectingHash, allow_duplicate_key: false)
      raise Error, "network policy must be a JSON object" unless data.is_a?(Hash)
      raise Error, "network policy has unknown or missing keys" unless data.keys.sort == POLICY_KEYS.sort

      mode = data.fetch("mode")
      raise Error, "invalid network mode: #{mode.inspect}" unless MODES.include?(mode)

      domains = string_array!(data.fetch("allowedDomains"), "allowedDomains") do |domain|
        normalized = domain.downcase
        raise Error, "invalid domain: #{domain.inspect}" unless normalized.match?(DOMAIN_PATTERN)

        normalized
      end
      cidrs = string_array!(data.fetch("allowedCIDRs"), "allowedCIDRs") do |cidr|
        normalize_cidr(cidr)
      end
      Policy.new(
        slot: slot,
        mode: mode,
        domains: domains.uniq.sort,
        cidrs: cidrs.uniq.sort,
        tcp_ports: port_array!(data.fetch("allowedTCPPorts"), "allowedTCPPorts"),
        udp_ports: port_array!(data.fetch("allowedUDPPorts"), "allowedUDPPorts")
      )
    rescue JSON::ParserError => e
      raise Error, "invalid network policy JSON: #{e.message}"
    end

    def string_array!(value, label)
      raise Error, "#{label} must be an array" unless value.instance_of?(Array)

      value.map do |entry|
        raise Error, "#{label} entries must be strings" unless entry.instance_of?(String)

        yield(entry)
      end
    end

    def port_array!(value, label)
      raise Error, "#{label} must be an array" unless value.instance_of?(Array)

      value.map do |port|
        raise Error, "invalid #{label} port: #{port.inspect}" unless port.instance_of?(Integer) && port.between?(1,
                                                                                                                 65_535)

        port
      end.uniq.sort
    end

    def normalize_cidr(value)
      raise Error, "invalid IPv4 CIDR: #{value.inspect}" unless %r{\A[^/]+/(?:\d|[12]\d|3[0-2])\z}.match?(value)

      address = IPAddr.new(value)
      raise Error, "invalid IPv4 CIDR: #{value.inspect}" unless address.ipv4?

      "#{address.to_range.first}/#{value.split("/").last}"
    rescue IPAddr::InvalidAddressError
      raise Error, "invalid IPv4 CIDR: #{value.inspect}"
    end

    def read_policy_input
      source = @stdin.read(MAX_POLICY_BYTES + 1)
      raise Error, "network policy exceeds #{MAX_POLICY_BYTES} bytes" if source.bytesize > MAX_POLICY_BYTES

      source
    end

    def delete_tap(slot)
      tap = tap_name(slot)
      return unless tap_exists?(tap)

      @runner.run!(@ip_path, "link", "delete", "dev", tap)
    end

    def remove_slot_files(slot)
      directory = slot_directory(slot)
      return unless File.directory?(directory)

      %w[policy.json dnsmasq.conf dnsmasq.pid dnsmasq.log].each do |name|
        FileUtils.rm_f(File.join(directory, name))
      end
      Dir.children(directory).each do |name|
        FileUtils.rm_f(File.join(directory, name)) if name.start_with?("dnsmasq-")
      end
      Dir.rmdir(directory)
    rescue Errno::ENOTEMPTY
      raise Error, "unexpected files in #{directory}"
    end

    def atomic_write(path, content)
      directory = File.dirname(path)
      Tempfile.create(["write-", ".tmp"], directory, mode: 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
        File.rename(file.path, path)
      end
    end

    def with_lock
      ensure_runtime_root!
      flags = File::RDWR | File::CREAT
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      File.open(File.join(@system.runtime_root, "lock"), flags, 0o600) do |lock|
        validate_lock!(lock)
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def ensure_runtime_root!
      Dir.mkdir(@system.runtime_root, 0o700)
    rescue Errno::EEXIST
      validate_secure_directory!(@system.runtime_root)
    end

    def ensure_slot_directory!(slot)
      directory = slot_directory(slot)
      Dir.mkdir(directory, 0o700)
      directory
    rescue Errno::EEXIST
      validate_secure_directory!(directory)
      directory
    end

    def validate_secure_directory!(path)
      stat = File.lstat(path)
      secure = stat.directory? && stat.uid == @system.root_uid && stat.mode.nobits?(0o022)
      raise Error, "unsafe runtime directory #{path}" unless secure
    end

    def validate_lock!(lock)
      stat = lock.stat
      secure = stat.file? && stat.uid == @system.root_uid && stat.mode.nobits?(0o022)
      raise Error, "unsafe lock file #{lock.path}" unless secure
    end

    def owner_uid!
      raise Error, "devbox-net must run as root" unless @system.euid.zero?

      integer!(@env["SUDO_UID"], "SUDO_UID", 1..MAX_UID)
    end

    def integer!(value, label, range)
      parsed = Integer(value, 10)
      raise ArgumentError unless parsed.to_s == value && range.cover?(parsed)

      parsed
    rescue ArgumentError, TypeError
      raise Error, "invalid #{label}: #{value.inspect}"
    end

    def require_arity!(command, arguments, expected)
      return if arguments.length == expected

      suffix = expected == 1 ? nil : "s"
      raise Error, "#{command} expects #{expected} argument#{suffix}"
    end

    def tap_name(slot)
      "devbox#{slot}"
    end

    def host_ip(slot)
      "10.#{NETWORK_PREFIX}.#{slot}.1"
    end

    def host_cidr(slot)
      "#{host_ip(slot)}/30"
    end

    def guest_ip(slot)
      "10.#{NETWORK_PREFIX}.#{slot}.2"
    end

    def slot_directory(slot)
      File.join(@system.runtime_root, slot.to_s)
    end

    def config_file(slot)
      File.join(slot_directory(slot), "dnsmasq.conf")
    end

    def pid_file(slot)
      File.join(slot_directory(slot), "dnsmasq.pid")
    end

    def log_file(slot)
      File.join(slot_directory(slot), "dnsmasq.log")
    end

    def tap_exists?(tap)
      File.directory?(File.join(@system.net_root, tap))
    end

    def default_system_context
      SystemContext.new(
        euid: Process.euid,
        root_uid: 0,
        runtime_root: "/run/devbox-net",
        net_root: "/sys/class/net",
        proc_root: "/proc",
        resolver_paths: ["/run/systemd/resolve/stub-resolv.conf", "/etc/resolv.conf"]
      )
    end

    def usage
      "usage: devbox-net ensure SLOT QUEUES | devbox-net apply-policy SLOT | " \
        "devbox-net delete SLOT | devbox-net reconcile"
    end
  end
end

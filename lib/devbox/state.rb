# frozen_string_literal: true

require "fileutils"
require "json"
require "tempfile"

module Devbox
  class State
    FORMAT_VERSION = 3
    NETWORK_PREFIX = 201
    IDENTITY_KEYS = %w[tap ip host_ip mac].freeze
    STATE_FILENAME = "state.json"
    RUNTIME_FILENAME = "runtime.json"
    BUILD_FILENAME = "build.json"
    LEGACY_VM_FILENAME = "vm.json"
    RUNTIME_KEYS = %w[status pid virtiofsd_pid forward_pid].freeze
    BUILD_KEYS = %w[ch virtiofsd toplevel kernel initrd cmdline nix_package closure_info].freeze

    def self.path_for(name)
      File.join(Paths.vm_dir(name), STATE_FILENAME)
    end

    def self.runtime_path_for(name)
      File.join(Paths.runtime_vm_dir(name), RUNTIME_FILENAME)
    end

    def self.build_path_for(name)
      File.join(Paths.cache_vm_dir(name), "build", BUILD_FILENAME)
    end

    def self.load(name)
      migrate_legacy(name)
      path = path_for(name)
      raise Error, "no VM named #{name.inspect} in #{Paths.state_root}" unless File.file?(path)

      durable = JSON.parse(File.read(path))
      durable, migrated = migrate_durable(durable)
      write_json(path, durable) if migrated
      runtime = read_json(runtime_path_for(name))
      build = read_json(build_path_for(name))
      new(durable, runtime: runtime, build: build)
    end

    def self.list
      root = Paths.state_root
      return [] unless File.directory?(root)

      Dir.children(root).sort.select do |name|
        File.file?(path_for(name)) || File.file?(legacy_vm_path_for(name))
      end
    end

    def self.resolve_name(name)
      return name unless name.nil? || name.empty?

      names = list
      case names.size
      when 0
        raise Error, "no VMs in #{Paths.state_root}; pass a name or create one"
      when 1
        names.first
      else
        raise Error, "multiple VMs (#{names.join(", ")}); pass a name"
      end
    end

    def self.migrate_legacy(name)
      legacy_vm = legacy_vm_path_for(name)
      return unless File.file?(legacy_vm)

      state_dir = Paths.vm_dir(name)
      cache_dir = Paths.cache_vm_dir(name)
      runtime_dir = Paths.runtime_vm_dir(name)
      durable = JSON.parse(File.read(legacy_vm))
      runtime = read_json(File.join(state_dir, STATE_FILENAME))
      build = durable.slice(*BUILD_KEYS)
      durable = durable.except(*BUILD_KEYS)
      durable["source_config"] = durable.delete("config") if durable.key?("config")
      durable["format_version"] = 2

      running = process_alive?(runtime["pid"])
      unless running
        runtime["status"] = "stopped"
        runtime["pid"] = nil
        runtime["virtiofsd_pid"] = nil unless process_alive?(runtime["virtiofsd_pid"])
      end

      FileUtils.mkdir_p(File.join(cache_dir, "build"))
      FileUtils.mkdir_p(File.join(cache_dir, "logs"))
      FileUtils.mkdir_p(runtime_dir, mode: 0o700)
      move(File.join(state_dir, "nix"), File.join(cache_dir, "guest-store", "nix"))
      %w[gcroots closure-info toplevel cloud-hypervisor virtiofsd].each do |entry|
        move(File.join(state_dir, entry), File.join(cache_dir, "build", entry))
      end
      move(File.join(state_dir, "cloud-hypervisor.log"), File.join(cache_dir, "logs", "cloud-hypervisor.log"))
      move(File.join(state_dir, "virtiofsd.log"), File.join(cache_dir, "logs", "virtiofsd.log"))
      %w[api.sock api.sock.lock console.sock virtiofs.sock virtiofs.sock.pid].each do |entry|
        move(File.join(state_dir, entry), File.join(runtime_dir, entry))
      end
      move(File.join(state_dir, "snap"), File.join(cache_dir, "legacy-snapshot"))

      build["ch"] = File.join(cache_dir, "build", "cloud-hypervisor", "bin", "cloud-hypervisor") if build["ch"]
      build["virtiofsd"] = File.join(cache_dir, "build", "virtiofsd", "bin", "virtiofsd") if build["virtiofsd"]
      repair_system_root(cache_dir, build["toplevel"])
      if running
        write_json(runtime_path_for(name), runtime)
      else
        FileUtils.rm_rf(runtime_dir)
      end
      write_json(build_path_for(name), build)
      write_json(path_for(name), durable)
      FileUtils.rm_f(legacy_vm)
    end

    def initialize(data = nil, runtime: nil, build: nil, **keywords)
      merged = stringify((data || {}).merge(keywords))
      @runtime = stringify(runtime || merged.slice(*RUNTIME_KEYS))
      @build = stringify(build || merged.slice(*BUILD_KEYS))
      @durable = merged.except(*RUNTIME_KEYS, *BUILD_KEYS, *IDENTITY_KEYS)
      @durable["format_version"] ||= FORMAT_VERSION
      @runtime["status"] ||= "stopped"
    end

    def [](key)
      key = key.to_s
      return network_identity[key] if IDENTITY_KEYS.include?(key)
      return @runtime[key] if RUNTIME_KEYS.include?(key)
      return @build[key] if BUILD_KEYS.include?(key)

      @durable[key]
    end

    def []=(key, value)
      key = key.to_s
      raise Error, "#{key} is derived from slot and cannot be assigned" if IDENTITY_KEYS.include?(key)

      if RUNTIME_KEYS.include?(key)
        @runtime[key] = value
      elsif BUILD_KEYS.include?(key)
        @build[key] = value
      else
        @durable[key] = value
      end
    end

    def name
      @durable.fetch("name")
    end

    def status
      @runtime["status"]
    end

    def dir
      Paths.vm_dir(name)
    end

    def cache_dir
      Paths.cache_vm_dir(name)
    end

    def runtime_dir
      Paths.runtime_vm_dir(name)
    end

    def disk
      File.join(dir, "persist.qcow2")
    end

    alias persist disk

    def project_dir
      File.join(dir, "nix")
    end

    def default_nix
      File.join(project_dir, "default.nix")
    end

    def machine_nix
      File.join(project_dir, "machine.nix")
    end

    def store_root
      File.join(cache_dir, "guest-store")
    end

    def store_dir
      File.join(store_root, "nix", "store")
    end

    def build_dir
      File.join(cache_dir, "build")
    end

    def virtiofs_socket
      File.join(runtime_dir, "virtiofs.sock")
    end

    def virtiofs_log
      File.join(cache_dir, "logs", "virtiofsd.log")
    end

    def api_socket
      File.join(runtime_dir, "api.sock")
    end

    def hypervisor_log
      File.join(cache_dir, "logs", "cloud-hypervisor.log")
    end

    def console_socket
      File.join(runtime_dir, "console.sock")
    end

    def forward_control_socket
      File.join(runtime_dir, "forward-control.sock")
    end

    def forward_log
      File.join(cache_dir, "logs", "ssh-forward.log")
    end

    def ssh_dir
      File.join(dir, "ssh")
    end

    def known_hosts
      File.join(ssh_dir, "known_hosts")
    end

    def build_ready?
      required = %w[ch virtiofsd kernel initrd cmdline toplevel]
      metadata = required.all? { |key| self[key] && !self[key].to_s.empty? }
      system = self["toplevel"] && File.join(store_dir, File.basename(self["toplevel"]))
      metadata && File.executable?(self["ch"]) && File.executable?(self["virtiofsd"]) && File.exist?(system)
    end

    def save
      FileUtils.mkdir_p(dir)
      FileUtils.mkdir_p(build_dir)
      self.class.send(:write_json, self.class.path_for(name), @durable)
      self.class.send(:write_json, self.class.build_path_for(name), @build)
      if @runtime["pid"] || @runtime["virtiofsd_pid"] || @runtime["forward_pid"] || @runtime["status"] == "running"
        FileUtils.mkdir_p(runtime_dir, mode: 0o700)
        self.class.send(:write_json, self.class.runtime_path_for(name), @runtime)
      else
        FileUtils.rm_rf(runtime_dir)
      end
      self
    end

    def save_runtime
      if @runtime["pid"] || @runtime["virtiofsd_pid"] || @runtime["forward_pid"] || @runtime["status"] == "running"
        FileUtils.mkdir_p(runtime_dir, mode: 0o700)
        self.class.send(:write_json, self.class.runtime_path_for(name), @runtime)
      else
        FileUtils.rm_rf(runtime_dir)
      end
      self
    end

    def durable
      @durable.dup
    end

    def to_h
      @durable.merge(network_identity, @build, @runtime)
    end

    def reload
      fresh = self.class.load(name)
      @durable = fresh.durable
      @build = stringify(fresh.to_h.slice(*BUILD_KEYS))
      @runtime = stringify(fresh.to_h.slice(*RUNTIME_KEYS))
      self
    end

    private

    def stringify(data)
      (data || {}).to_h.transform_keys(&:to_s)
    end

    class << self
      private

      def legacy_vm_path_for(name)
        File.join(Paths.vm_dir(name), LEGACY_VM_FILENAME)
      end

      def read_json(path)
        File.file?(path) ? JSON.parse(File.read(path)) : {}
      end

      def migrate_durable(data)
        version = Integer(data.fetch("format_version", 2))
        return [data, false] if version >= FORMAT_VERSION

        migrated = data.dup
        slot = migrated["slot"] || slot_from_identity(migrated)
        raise Error, "cannot migrate #{migrated["name"].inspect}: missing network slot" if slot.nil?

        slot = Integer(slot)
        raise Error, "cannot migrate #{migrated["name"].inspect}: invalid network slot" unless slot.between?(0, 255)

        migrated["slot"] = slot
        migrated["network_prefix"] = 24
        IDENTITY_KEYS.each { |key| migrated.delete(key) }
        migrated["format_version"] = FORMAT_VERSION
        [migrated, true]
      rescue ArgumentError, TypeError
        raise Error, "cannot migrate #{data["name"].inspect}: invalid network slot"
      end

      def slot_from_identity(data)
        tap_match = /\Adevbox(\d+)\z/.match(data["tap"].to_s)
        return Integer(tap_match[1]) if tap_match

        ip_match = /\A10\.#{NETWORK_PREFIX}\.(\d+)\.[12]\z/.match(data["ip"].to_s)
        ip_match && Integer(ip_match[1])
      end

      def write_json(path, data)
        FileUtils.mkdir_p(File.dirname(path))
        Tempfile.create([".#{File.basename(path)}-", ".tmp"], File.dirname(path), mode: 0o600) do |file|
          file.write("#{JSON.pretty_generate(data)}\n")
          file.flush
          file.fsync
          File.rename(file.path, path)
        end
      end

      def process_alive?(pid)
        return false if pid.nil?

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end

      def move(source, destination)
        return unless File.exist?(source) || File.symlink?(source)
        return if File.exist?(destination) || File.symlink?(destination)

        FileUtils.mkdir_p(File.dirname(destination))
        FileUtils.mv(source, destination)
      end

      def repair_system_root(cache_dir, toplevel)
        return unless toplevel

        root = File.join(cache_dir, "build", "gcroots", "system")
        target = File.join(cache_dir, "guest-store", "nix", "store", File.basename(toplevel))
        return unless File.exist?(target)

        FileUtils.mkdir_p(File.dirname(root))
        FileUtils.rm_f(root)
        FileUtils.ln_s(target, root)
      end
    end

    def network_identity
      slot = @durable["slot"]
      return {} if slot.nil?

      slot = Integer(slot)
      raise Error, "invalid network slot #{slot.inspect}" unless slot.between?(0, 255)

      {
        "tap" => "devbox#{slot}",
        "ip" => "10.#{NETWORK_PREFIX}.#{slot}.2",
        "host_ip" => "10.#{NETWORK_PREFIX}.#{slot}.1",
        "mac" => format("02:db:00:00:%02x:02", slot)
      }
    rescue ArgumentError, TypeError
      raise Error, "invalid network slot #{slot.inspect}"
    end
  end
end

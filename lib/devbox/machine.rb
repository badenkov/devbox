# frozen_string_literal: true

require "etc"
require "fileutils"
require "json"
require "pathname"
require "shellwords"
require "tmpdir"

module Devbox
  class Machine
    NAME_PATTERN = /\A[a-z][a-z0-9-]{0,31}\z/

    def self.create(config, name = nil, **opts)
      new(**opts).create(config, name)
    end

    def self.start(name = nil, **opts)
      new(**opts).start(name)
    end

    def self.stop(name = nil, **opts)
      new(**opts).stop(name)
    end

    def self.apply(config, name = nil, **opts)
      new(**opts).apply(config, name)
    end

    def self.ls(**opts)
      new(**opts).ls
    end

    def self.status(name, **opts)
      new(**opts).status(name)
    end

    def self.ssh(name = nil, cmd = [], **opts)
      new(**opts).ssh(name, cmd)
    end

    def self.shell(name = nil, **opts)
      new(**opts).shell(name)
    end

    def self.exec(name, cmd, interactive: false, tty: false, **opts)
      new(**opts).exec(name, cmd, interactive: interactive, tty: tty)
    end

    def self.forward(name, mapping, **opts)
      new(**opts).forward(name, mapping)
    end

    def self.console(name = nil, **opts)
      new(**opts).console(name)
    end

    def self.logs(name = nil, follow: false, **opts)
      new(**opts).logs(name, follow: follow)
    end

    def self.rm(name, **opts)
      new(**opts).rm(name)
    end

    def initialize(nix: Nix.new, runner: Runner.new, io: $stdout)
      @nix = nix
      @runner = runner
      @io = io
    end

    def create(config, name = nil)
      config = File.expand_path(config)
      raise Error, "config not found: #{config}" unless File.file?(config)

      FileUtils.mkdir_p(Paths.cache_root)
      Dir.mktmpdir("devbox-create-", Paths.cache_root) do |staging|
        @nix.prepare_project(config, staging)
        initial_info = @nix.evaluate(staging)
        name = resolve_vm_name(name, initial_info)
        state = State.new("name" => name)
        raise Error, "VM #{name.inspect} already exists at #{state.dir}" if File.exist?(state.dir)

        FileUtils.mkdir_p(state.dir)
        FileUtils.cp_r(staging, state.project_dir)
        state["source_config"] = config
        slot = next_slot
        state["slot"] = slot
        state["network_prefix"] = 30

        base_info = @nix.evaluate(state.project_dir)
        install_ssh_key(state, base_info["sshKey"])
        write_machine_module(state)
        info = @nix.evaluate(state.project_dir)
        nixpkgs = @nix.nixpkgs_path(state.project_dir)
        realize_tools(state, nixpkgs)
        refresh_system(state, info, nixpkgs: nixpkgs)
        @nix.create_persist(state.persist, info.fetch("diskSizeGB")) unless File.exist?(state.persist)

        state["status"] = "stopped"
        record_spec(state, info, config: config)
        state.save
        say "created #{name} at #{state.dir}"
        state
      end
    end

    def start(name = nil)
      state = State.load(State.resolve_name(name))
      ensure_project(state)
      ensure_build(state)
      hypervisor = Hypervisor.new(state, runner: @runner)
      if state.status == "running" && hypervisor.running_pid?(state["pid"])
        raise Error, "#{state.name} is already running"
      end

      if hypervisor.disk_in_use?
        pid = hypervisor.discover_vmm_pid
        owner = pid ? " (pid #{pid})" : ""
        raise Error,
              "#{state.name} disk is already in use#{owner}; " \
              "run `devbox stop #{state.name}` to recover stale runtime state"
      end

      hypervisor.rotate_logs
      network_touched = true
      begin
        hypervisor.ensure_tap
        hypervisor.apply_network_policy
        FileUtils.rm_f(state.api_socket)
        virtiofsd_pid = hypervisor.start_virtiofsd
        state["virtiofsd_pid"] = virtiofsd_pid
        state.save

        pid = hypervisor.boot

        state["status"] = "running"
        state["pid"] = pid
        state.save
        Kernel.sleep(0.1)
        unless hypervisor.running_pid?(pid)
          raise Error, "cloud-hypervisor exited during startup; see `devbox logs #{state.name}`"
        end

        start_declarative_forwards(state) unless state["forward_ports"].to_a.empty?
      rescue StandardError => e
        cleanup_errors = cleanup_failed_start(state, hypervisor, network_touched: network_touched)
        raise if cleanup_errors.empty?

        raise Error, "#{e.message}; startup cleanup failed: #{cleanup_errors.join("; ")}"
      end
      say "started #{state.name} (pid #{pid})"
    end

    def stop(name = nil)
      state = State.load(State.resolve_name(name))
      hypervisor = Hypervisor.new(state, runner: @runner)
      tracked_pid = state["pid"] if hypervisor.running_pid?(state["pid"])
      disk_in_use = hypervisor.disk_in_use?
      orphan_pid = hypervisor.discover_vmm_pid if disk_in_use && !tracked_pid
      stop_declarative_forwards(state)

      case state.status
      when "stopped"
        unless disk_in_use
          state["virtiofsd_pid"] ||= hypervisor.discover_virtiofsd_pid
          hypervisor.stop_virtiofsd
          hypervisor.teardown_tap
          FileUtils.rm_f(state.api_socket)
          FileUtils.rm_f(state.console_socket)
          state["pid"] = nil
          state["virtiofsd_pid"] = nil
          state.save
          say "#{state.name} is already stopped"
          return
        end
        unless orphan_pid
          raise Error, "#{state.name} disk is in use, but the owning Cloud Hypervisor process was not found"
        end

        say "recovering #{state.name} from stale runtime state (pid #{orphan_pid})"
        hypervisor.terminate(orphan_pid)
      when "running"
        state["status"] = "stopped"
        state.save
        if tracked_pid
          hypervisor.shutdown_guest
          hypervisor.wait_until_dead(tracked_pid)
        elsif orphan_pid
          say "recovering #{state.name} from stale runtime state (pid #{orphan_pid})"
          hypervisor.terminate(orphan_pid)
        end
      else
        raise Error, "cannot stop #{state.name} from #{state.status}"
      end

      state["virtiofsd_pid"] ||= hypervisor.discover_virtiofsd_pid
      hypervisor.stop_virtiofsd
      hypervisor.teardown_tap
      FileUtils.rm_f(state.api_socket)
      FileUtils.rm_f(state.console_socket)
      state["pid"] = nil
      state["virtiofsd_pid"] = nil
      state["status"] = "stopped"
      state.save
      say "stopped #{state.name}"
    end

    def rm(name)
      raise Error, "pass a VM name" unless present?(name)

      state = State.load(name)
      hypervisor = Hypervisor.new(state, runner: @runner)
      stop_declarative_forwards(state)
      if state.status == "running" && hypervisor.running_pid?(state["pid"])
        state["status"] = "stopped"
        state.save
        hypervisor.shutdown_guest
        hypervisor.wait_until_dead(state["pid"])
      end
      hypervisor.stop_virtiofsd
      hypervisor.teardown_tap
      FileUtils.rm_f(state.api_socket)
      FileUtils.rm_f(state.console_socket)
      FileUtils.rm_rf(state.dir)
      FileUtils.rm_rf(state.cache_dir)
      FileUtils.rm_rf(state.runtime_dir)
      say "removed #{name}"
    end

    def apply(config, name = nil)
      config = File.expand_path(config)
      raise Error, "config not found: #{config}" unless File.file?(config)

      state = State.load(resolve_apply_name(name, config))
      previous_kernel = state["kernel"]
      FileUtils.mkdir_p(Paths.state_root)
      FileUtils.mkdir_p(state.cache_dir)
      Dir.mktmpdir(".devbox-apply-#{state.name}-", Paths.state_root) do |state_staging|
        Dir.mktmpdir(".apply-", state.cache_dir) do |cache_staging|
          project = File.join(state_staging, "nix")
          build = File.join(cache_staging, "build")
          FileUtils.mkdir_p(build)
          prepare_candidate_project(state, config, project)
          info = @nix.evaluate(project)
          candidate = candidate_state(state)
          record_spec(candidate, info, config: config)
          nixpkgs = @nix.nixpkgs_path(project)
          realize_tools(candidate, nixpkgs, build_dir: build, final_build_dir: state.build_dir)
          refresh_system(candidate, info, nixpkgs: nixpkgs, project: project, build_dir: build)

          apply_candidate(state, candidate, info, project: project, build: build)
        end
      end

      if state.status == "running" && previous_kernel && previous_kernel != State.load(state.name)["kernel"]
        say "kernel changed; run `devbox stop #{state.name}` and `devbox start #{state.name}` to boot it"
      end
      say "#{state.name} is not running; store updated for the next start" unless state.status == "running"
      say "applied #{config} to #{state.name}"
    end

    def ls
      names = State.list
      if names.empty?
        say "no VMs in #{Paths.state_root}"
        return
      end

      rows = names.map do |name|
        state = State.load(name)
        ensure_project(state)
        [state.name, effective_status(state), "#{state["memory_mb"]}M", state["vcpus"].to_s, state["ip"].to_s]
      end
      headers = %w[NAME STATUS MEMORY VCPUS IP]
      widths = headers.each_index.map do |index|
        ([headers[index]] + rows.map { |row| row[index] }).map(&:length).max
      end
      say format_row(headers, widths)
      rows.each { |row| say format_row(row, widths) }
    end

    def status(name)
      state = State.load(name)
      ensure_project(state)
      fields = {
        "name" => state.name,
        "status" => effective_status(state),
        "pid" => state["pid"],
        "forward_pid" => state["forward_pid"],
        "memory_mb" => state["memory_mb"],
        "vcpus" => state["vcpus"],
        "disk_size_gb" => state["disk_size_gb"],
        "user" => state["user"],
        "ip" => state["ip"],
        "host_ip" => state["host_ip"],
        "tap" => state["tap"],
        "mac" => state["mac"],
        "network_prefix" => state["network_prefix"],
        "network" => state["network"],
        "forward_ports" => state["forward_ports"],
        "source_config" => state["source_config"],
        "ssh_public_key" => state["ssh_public_key"],
        "kernel" => state["kernel"],
        "toplevel" => state["toplevel"],
        "state_dir" => state.dir,
        "cache_dir" => state.cache_dir,
        "runtime_dir" => state.runtime_dir
      }
      width = fields.keys.map(&:length).max
      fields.each do |key, value|
        next if value.nil?

        say "#{key.ljust(width)}  #{value}"
      end
    end

    def ssh(name = nil, cmd = [])
      state = running_state(name)

      @runner.exec!(*ssh_argv(state, *cmd))
    end

    def shell(name = nil)
      state = running_state(name)
      @runner.exec!("ssh", *ssh_args(state), "-t", "#{state["user"]}@#{state["ip"]}")
    end

    def exec(name, cmd, interactive: false, tty: false)
      raise Error, "pass a command after --" if cmd.empty?

      state = running_state(name)
      transport = []
      transport << "-n" unless interactive
      transport << (tty ? "-t" : "-T")
      remote_command = Shellwords.join(cmd)
      @runner.exec!("ssh", *ssh_args(state), *transport, "#{state["user"]}@#{state["ip"]}", remote_command)
    end

    def forward(name, mapping)
      state = running_state(name)
      host_port, guest_port = parse_forward_mapping(mapping)
      target = "#{state["user"]}@#{state["ip"]}"
      @runner.exec!(
        "ssh", *ssh_args(state), "-N", "-T",
        "-o", "ExitOnForwardFailure=yes",
        "-L", "127.0.0.1:#{host_port}:127.0.0.1:#{guest_port}",
        target
      )
    end

    def console(name = nil)
      state = running_state(name)
      wait_for_console(state)
      say "connecting to #{state.name}; press Ctrl-] to detach"
      @runner.exec!("socat", "-,rawer,escape=0x1d", "UNIX-CONNECT:#{state.console_socket}")
    end

    def logs(name = nil, follow: false)
      state = State.load(State.resolve_name(name))
      raise Error, "no hypervisor log for #{state.name}" unless File.file?(state.hypervisor_log)

      if follow
        @runner.exec!("tail", "-n", "200", "-f", state.hypervisor_log)
      else
        @io.write(File.read(state.hypervisor_log))
      end
    end

    private

    def running_state(name)
      state = State.load(State.resolve_name(name))
      hypervisor = Hypervisor.new(state, runner: @runner)
      running = state.status == "running" && hypervisor.running_pid?(state["pid"])
      raise Error, "#{state.name} is not running" unless running

      state
    end

    def effective_status(state)
      return state.status unless state.status == "running"

      hypervisor = Hypervisor.new(state, runner: @runner)
      return "running" if hypervisor.running_pid?(state["pid"])

      state["status"] = "stopped"
      state["pid"] = nil
      state["virtiofsd_pid"] = nil unless hypervisor.running_pid?(state["virtiofsd_pid"])
      state.save
      "stopped"
    end

    def cleanup_failed_start(state, hypervisor, network_touched:)
      errors = []
      begin
        stop_declarative_forwards(state)
      rescue StandardError => e
        errors << e.message
      end
      if hypervisor.running_pid?(state["pid"])
        begin
          hypervisor.shutdown_guest
          hypervisor.wait_until_dead(state["pid"])
        rescue StandardError => e
          errors << e.message
          hypervisor.terminate(state["pid"])
        end
      end
      begin
        hypervisor.stop_virtiofsd
      rescue StandardError => e
        errors << e.message
      end
      if network_touched
        begin
          hypervisor.teardown_tap
        rescue StandardError => e
          errors << e.message
        end
      end
      FileUtils.rm_f(state.api_socket)
      FileUtils.rm_f(state.console_socket)
      state["status"] = "stopped"
      state["pid"] = nil
      state["virtiofsd_pid"] = nil
      state["forward_pid"] = nil
      state.save
      errors
    end

    def wait_for_console(state)
      deadline = Time.now + 5
      Kernel.sleep(0.05) until File.exist?(state.console_socket) || Time.now >= deadline
      return if File.exist?(state.console_socket)

      raise Error, "console socket is not available; see `devbox logs #{state.name}`"
    end

    def say(message)
      @io.puts(message)
    end

    def format_row(cells, widths)
      cells.each_index.map { |index| cells[index].ljust(widths[index]) }.join("  ")
    end

    def record_spec(state, info, config:)
      state["source_config"] = config
      state["user"] = info.fetch("user")
      state["memory_mb"] = info.fetch("memoryMB")
      state["vcpus"] = info.fetch("vcpus")
      state["disk_size_gb"] = info.fetch("diskSizeGB")
      state["network"] = info.fetch("network")
      state["forward_ports"] = info.fetch("forwardPorts")
    end

    def generate_ssh_key(state)
      key = File.join(state.ssh_dir, "id_ed25519")
      pub = "#{key}.pub"
      return pub if File.file?(pub)

      @runner.capture!("ssh-keygen", "-t", "ed25519", "-f", key, "-N", "", "-C", "devbox@#{state.name}")
      pub
    end

    def install_ssh_key(state, source)
      FileUtils.mkdir_p(state.ssh_dir)
      source ||= generate_ssh_key(state)
      authorized = File.join(state.ssh_dir, "authorized_key.pub")
      FileUtils.cp(source, authorized) unless File.expand_path(source) == File.expand_path(authorized)
      private_key = source.sub(/\.pub\z/, "")
      state["ssh_public_key"] = "ssh/authorized_key.pub"
      if File.file?(private_key) && File.dirname(File.expand_path(private_key)) == File.expand_path(state.ssh_dir)
        state["ssh_private_key"] = "ssh/#{File.basename(private_key)}"
      end
      authorized
    end

    def write_machine_module(state, project: state.project_dir)
      FileUtils.mkdir_p(project)
      File.write(File.join(project, "machine.nix"), <<~NIX)
        { lib, ... }: {
          devbox.name = lib.mkForce #{JSON.generate(state.name)};
          devbox.ip = #{JSON.generate(state["ip"])};
          devbox.gateway = #{JSON.generate(state["host_ip"])};
          devbox.prefixLength = #{Integer(state["network_prefix"] || 30)};
          devbox.sshKey = ../ssh/authorized_key.pub;
        }
      NIX
      File.join(project, "machine.nix")
    end

    def resolve_vm_name(cli_name, info)
      name = present?(cli_name) ? cli_name : info["name"]
      raise Error, "pass a VM name or set devbox.name in the config" unless present?(name)
      raise Error, "invalid VM name #{name.inspect} (expected [a-z][a-z0-9-]{0,31})" unless name.match?(NAME_PATTERN)

      name
    end

    def present?(value)
      !(value.nil? || value.to_s.empty?)
    end

    def resolve_apply_name(name, config)
      return name if present?(name)

      matches = State.list.select do |candidate|
        source = State.load(candidate)["source_config"]
        source && File.expand_path(source) == File.expand_path(config)
      end
      return matches.first if matches.one?

      State.resolve_name(nil)
    end

    def ensure_project(state)
      return if File.file?(state.default_nix)

      config = state["source_config"]
      raise Error, "VM #{state.name} has no recoverable Nix project" unless config && File.file?(config)

      @nix.prepare_project(config, state.project_dir)
      source_key = resolve_state_path(state, state["ssh_public_key"])
      install_ssh_key(state, source_key)
      write_machine_module(state)
      FileUtils.rm_f(File.join(state.dir, "wrapper.nix"))
      FileUtils.rm_f(File.join(state.dir, "runtime.nix"))
      state.save
    end

    def ensure_build(state)
      return if state.build_ready?

      nixpkgs = @nix.nixpkgs_path(state.project_dir)
      realize_tools(state, nixpkgs)
      info = @nix.evaluate(state.project_dir)
      refresh_system(state, info, nixpkgs: nixpkgs)
      record_spec(state, info, config: state["source_config"])
      state.save
    end

    def realize_tools(state, nixpkgs, build_dir: state.build_dir, final_build_dir: build_dir)
      tools = @nix.realize_tools(nixpkgs: nixpkgs, gc_root_dir: build_dir)
      state["ch"] = relocate_build_path(tools.fetch("cloudHypervisor"), build_dir, final_build_dir)
      state["virtiofsd"] = relocate_build_path(tools.fetch("virtiofsd"), build_dir, final_build_dir)
    end

    def refresh_system(state, info, nixpkgs:, project: state.project_dir, build_dir: state.build_dir)
      @nix.build_system(project: project, nixpkgs: nixpkgs, gc_root_dir: build_dir)
      closure = @nix.closure_info(nixpkgs: nixpkgs, toplevel: info.fetch("toplevel"),
                                  gc_root_dir: build_dir)
      extra = [info["nixPackage"], closure].compact
      @nix.populate_store(
        store_root: state.store_root,
        gc_root_dir: File.join(build_dir, "gcroots"),
        toplevel: info.fetch("toplevel"),
        extra: extra,
        closure_info: closure
      )
      state["toplevel"] = info.fetch("toplevel")
      state["kernel"] = info.fetch("kernel")
      state["initrd"] = info.fetch("initrd")
      state["cmdline"] = @nix.cmdline(info)
      state["nix_package"] = info["nixPackage"]
      state["closure_info"] = closure
    end

    def prepare_candidate_project(state, config, project)
      current_npins = File.join(state.project_dir, "npins")
      FileUtils.mkdir_p(project)
      FileUtils.cp_r(current_npins, File.join(project, "npins"), preserve: true) if File.directory?(current_npins)
      @nix.prepare_project(config, project, preserve_npins: true)
      staging_ssh = File.join(File.dirname(project), "ssh")
      FileUtils.mkdir_p(staging_ssh)
      FileUtils.cp(resolve_state_path(state, state["ssh_public_key"]),
                   File.join(staging_ssh, "authorized_key.pub"), preserve: true)
      write_machine_module(state, project: project)
    end

    def candidate_state(state)
      data = state.durable
      runtime = state.to_h.slice(*State::RUNTIME_KEYS)
      build = state.to_h.slice(*State::BUILD_KEYS)
      State.new(data, runtime: runtime, build: build)
    end

    def apply_candidate(state, candidate, info, project:, build:)
      running = state.status == "running"
      old_hypervisor = Hypervisor.new(state, runner: @runner)
      raise Error, "#{state.name} VMM is not running" if running && !old_hypervisor.running_pid?(state["pid"])

      policy_applied = false
      guest_activated = false
      rollback_forwards = nil
      begin
        if running
          wait_for_ssh(state)
          Hypervisor.new(candidate, runner: @runner).apply_network_policy
          policy_applied = true
          switch_guest(state, info)
          guest_activated = true
          rollback_forwards = reconcile_declarative_forwards(state, candidate)
        end
        commit_candidate(state, candidate, project: project, build: build)
      rescue StandardError => e
        rollback_errors = []
        rollback_layer(rollback_errors, "forwards") { rollback_forwards&.call }
        if guest_activated
          rollback_layer(rollback_errors, "guest system") do
            switch_guest(state, "toplevel" => state["toplevel"])
          end
        end
        rollback_layer(rollback_errors, "host policy") { old_hypervisor.apply_network_policy } if policy_applied
        raise e if rollback_errors.empty?

        raise Error, "#{e.message}; rollback failed: #{rollback_errors.join("; ")}"
      end
    end

    def rollback_layer(errors, label)
      yield
    rescue StandardError => e
      errors << "#{label}: #{e.message}"
    end

    def commit_candidate(state, candidate, project:, build:)
      project_backup = File.join(File.dirname(project), "previous-nix")
      build_backup = File.join(File.dirname(build), "previous-build")
      project_had_previous = File.exist?(state.project_dir)
      build_had_previous = File.exist?(state.build_dir)
      project_replaced = false
      build_replaced = false
      begin
        FileUtils.mv(state.project_dir, project_backup) if project_had_previous
        FileUtils.mv(project, state.project_dir)
        project_replaced = true
        FileUtils.mv(state.build_dir, build_backup) if build_had_previous
        FileUtils.mv(build, state.build_dir)
        build_replaced = true
        candidate.save
      rescue StandardError
        FileUtils.rm_rf(state.build_dir) if build_replaced
        FileUtils.mv(build_backup, state.build_dir) if build_had_previous && File.exist?(build_backup)
        FileUtils.rm_rf(state.project_dir) if project_replaced
        FileUtils.mv(project_backup, state.project_dir) if project_had_previous && File.exist?(project_backup)
        state.save
        raise
      end
      FileUtils.rm_rf(project_backup)
      FileUtils.rm_rf(build_backup)
    end

    def relocate_build_path(path, source, destination)
      expanded = File.expand_path(path)
      prefix = "#{File.expand_path(source)}/"
      return path unless expanded.start_with?(prefix)

      File.join(destination, expanded.delete_prefix(prefix))
    end

    def switch_guest(state, info)
      target = "#{state["user"]}@#{state["ip"]}"
      toplevel = info.fetch("toplevel")
      script = <<~SH
        set -euo pipefail
        #{toplevel}/bin/switch-to-configuration switch
      SH
      @runner.capture!("ssh", *ssh_args(state), target, "sudo bash -s", stdin_data: script)
    end

    def next_slot
      used = State.list.filter_map { |name| State.load(name)["slot"] }
      slot = (0..255).find { |candidate| !used.include?(candidate) }
      raise Error, "no free TAP slots in 10.#{State::NETWORK_PREFIX}.0.0/16" unless slot

      slot
    end

    def ssh_args(state)
      key = resolve_state_path(state, state["ssh_private_key"])
      opts = [
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=#{state.known_hosts}",
        "-o", "BatchMode=yes"
      ]
      opts.unshift("-i", key) if key && File.file?(key)
      opts
    end

    def resolve_state_path(state, path)
      return nil unless path
      return path if Pathname.new(path).absolute?

      File.join(state.dir, path)
    end

    def ssh_argv(state, *remote)
      ["ssh", *ssh_args(state), "#{state["user"]}@#{state["ip"]}", *remote]
    end

    def start_declarative_forwards(state, persist: true)
      forwards = validate_declarative_forwards(state["forward_ports"])
      return if forwards.empty?

      wait_for_ssh(state)
      stop_declarative_forwards(state)
      FileUtils.mkdir_p(state.runtime_dir, mode: 0o700)
      FileUtils.rm_f(state.forward_control_socket)
      target = "#{state["user"]}@#{state["ip"]}"
      args = [
        "ssh", *ssh_args(state), "-N", "-T", "-M", "-S", state.forward_control_socket,
        "-o", "ControlPersist=no", "-o", "ExitOnForwardFailure=yes",
        "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"
      ]
      forwards.each do |forward|
        args.push("-L", "#{forward.fetch("bind")}:#{forward.fetch("hostPort")}:127.0.0.1:#{forward.fetch("guestPort")}")
      end
      args << target
      state["forward_pid"] = @runner.spawn_background(*args, log: state.forward_log)
      state.save_runtime if persist
      wait_for_forward_control(state, target)
    rescue StandardError
      stop_declarative_forwards(state)
      raise
    end

    def reconcile_declarative_forwards(previous, candidate)
      old_forwards = validate_declarative_forwards(previous["forward_ports"])
      new_forwards = validate_declarative_forwards(candidate["forward_ports"])
      if old_forwards.empty?
        return -> {} if new_forwards.empty?

        start_declarative_forwards(candidate, persist: false)
        return lambda do
          stop_declarative_forwards(candidate)
          previous["forward_pid"] = nil
        end
      end
      if new_forwards.empty?
        stop_declarative_forwards(previous)
        candidate["forward_pid"] = nil
        return -> { start_declarative_forwards(previous, persist: false) }
      end

      removed = old_forwards - new_forwards
      added = new_forwards - old_forwards
      target = "#{previous["user"]}@#{previous["ip"]}"
      completed_removed = []
      completed_added = []
      begin
        removed.each do |forward|
          forward_control(previous, target, "cancel", forward)
          completed_removed << forward
        end
        added.each do |forward|
          forward_control(previous, target, "forward", forward)
          completed_added << forward
        end
      rescue StandardError
        completed_added.reverse_each { |forward| forward_control(previous, target, "cancel", forward) }
        completed_removed.reverse_each { |forward| forward_control(previous, target, "forward", forward) }
        raise
      end
      candidate["forward_pid"] = previous["forward_pid"]
      lambda do
        completed_added.reverse_each { |forward| forward_control(previous, target, "cancel", forward) }
        completed_removed.reverse_each { |forward| forward_control(previous, target, "forward", forward) }
      end
    end

    def forward_control(state, target, operation, forward)
      spec = "#{forward.fetch("bind")}:#{forward.fetch("hostPort")}:127.0.0.1:#{forward.fetch("guestPort")}"
      args = ["ssh", "-S", state.forward_control_socket, "-O", operation]
      args.push("-o", "ExitOnForwardFailure=yes") if operation == "forward"
      @runner.capture!(*args, "-L", spec, target)
    end

    def stop_declarative_forwards(state)
      target = "#{state["user"]}@#{state["ip"]}" if state["user"] && state["ip"]
      pid = state["forward_pid"]
      pid = discover_forward_pid(state) unless process_alive?(pid)
      if target && File.exist?(state.forward_control_socket)
        begin
          @runner.capture!("ssh", "-S", state.forward_control_socket, "-O", "exit", target)
        rescue Error
          nil
        end
      end
      terminate_process(pid)
      FileUtils.rm_f(state.forward_control_socket)
      state["forward_pid"] = nil
    end

    def wait_for_forward_control(state, target)
      deadline = Time.now + 5
      loop do
        if File.exist?(state.forward_control_socket)
          @runner.capture!("ssh", "-S", state.forward_control_socket, "-O", "check", target)
          return
        end
        unless process_alive?(state["forward_pid"])
          raise Error, "SSH forwarding failed; see #{state.forward_log} (a host port may already be in use)"
        end
        break if Time.now >= deadline

        Kernel.sleep(0.05)
      end
      raise Error, "SSH forwarding did not create #{state.forward_control_socket}; see #{state.forward_log}"
    rescue Error => e
      if File.exist?(state.forward_control_socket)
        raise Error, "SSH forwarding failed: #{e.message}; see #{state.forward_log}"
      end

      raise
    end

    def validate_declarative_forwards(forwards)
      Array(forwards).map do |forward|
        bind = forward.fetch("bind")
        raise Error, "forward bind must be 127.0.0.1" unless bind == "127.0.0.1"

        {
          "bind" => bind,
          "hostPort" => validate_port(forward.fetch("hostPort"), "host port"),
          "guestPort" => validate_port(forward.fetch("guestPort"), "guest port")
        }
      rescue KeyError
        raise Error, "invalid declarative forward #{forward.inspect}"
      end
    end

    def parse_forward_mapping(mapping)
      match = /\A([0-9]+)(?::([0-9]+))?\z/.match(mapping.to_s)
      raise Error, "invalid forward #{mapping.inspect} (expected HOST[:GUEST])" unless match

      host_port = validate_port(match[1], "host port")
      guest_port = validate_port(match[2] || match[1], "guest port")
      [host_port, guest_port]
    end

    def validate_port(value, label)
      port = value.is_a?(Integer) ? value : Integer(value, 10)
      raise Error, "invalid #{label} #{value.inspect} (expected 1..65535)" unless port.between?(1, 65_535)

      port
    rescue ArgumentError, TypeError
      raise Error, "invalid #{label} #{value.inspect} (expected 1..65535)"
    end

    def discover_forward_pid(state)
      socket = state.forward_control_socket
      Dir.glob("/proc/[0-9]*/cmdline").each do |path|
        args = File.binread(path).split("\0")
        next unless File.basename(args.first.to_s) == "ssh"
        next unless args.each_cons(2).any? { |option, value| option == "-S" && value == socket }

        return File.basename(File.dirname(path)).to_i
      rescue Errno::EACCES, Errno::ENOENT, Errno::ESRCH
        next
      end
      nil
    end

    def process_alive?(pid)
      return false if pid.nil?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def terminate_process(pid)
      return unless process_alive?(pid)

      Process.kill("TERM", pid)
      deadline = Time.now + 2
      while process_alive?(pid) && Time.now < deadline
        begin
          return if Process.wait(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          nil
        end
        Kernel.sleep(0.05)
      end
      Process.kill("KILL", pid) if process_alive?(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def wait_for_ssh(state)
      deadline = Time.now + 60
      loop do
        @runner.capture!(*ssh_argv(state, "true"))
        return
      rescue Error
        raise Error, "could not SSH to #{state["user"]}@#{state["ip"]}" if Time.now >= deadline

        Kernel.sleep(1)
      end
    end
  end
end

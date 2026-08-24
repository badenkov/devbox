# frozen_string_literal: true

require "json"
require "stringio"
require "test_helper"

class Devbox::MachineTest < Minitest::Test
  class FakeNix
    def prepare_project(config, project, **)
      FileUtils.mkdir_p(File.join(project, "npins"))
      FileUtils.mkdir_p(File.join(project, "user"))
      File.write(File.join(project, "npins", "default.nix"), "{}\n")
      File.write(File.join(project, "default.nix"), "{}\n")
      File.write(File.join(project, "machine.nix"), "{}\n")
      FileUtils.cp(config, File.join(project, "user", File.basename(config)))
    end

    def evaluate(*)
      {
        "name" => "try",
        "memoryMB" => 2048,
        "vcpus" => 2,
        "diskSizeGB" => 8,
        "user" => "dev",
        "sshKey" => nil,
        "ip" => nil,
        "gateway" => nil,
        "prefixLength" => 30,
        "network" => {
          "mode" => "allowlist",
          "allowedDomains" => ["github.com"],
          "allowedCIDRs" => [],
          "allowedTCPPorts" => [80, 443],
          "allowedUDPPorts" => []
        },
        "forwardPorts" => [
          { "bind" => "127.0.0.1", "hostPort" => 3000, "guestPort" => 3000 }
        ],
        "toplevel" => "/nix/store/fake-system",
        "kernel" => "/nix/store/fake-kernel/bzImage",
        "initrd" => "/nix/store/fake-initrd/initrd",
        "kernelParams" => [],
        "nixPackage" => "/nix/store/fake-nix"
      }
    end

    def nixpkgs_path(*)
      "/nixpkgs"
    end

    def build_system(**); end

    def closure_info(**)
      "/nix/store/fake-closure"
    end

    def populate_store(store_root:, toplevel:, **)
      FileUtils.mkdir_p(File.join(store_root, "nix", "store", File.basename(toplevel)))
    end

    def create_persist(dest, *)
      FileUtils.mkdir_p(File.dirname(dest))
      File.write(dest, "qcow")
      dest
    end

    def cmdline(info)
      "init=#{info.fetch("toplevel")}/init"
    end

    def realize_tools(**)
      {
        "cloudHypervisor" => "/bin/cloud-hypervisor",
        "virtiofsd" => "/bin/virtiofsd"
      }
    end

    def nix_path(path)
      "(/. + #{JSON.generate(File.expand_path(path))})"
    end
  end

  class FakeRunner
    attr_reader :commands, :stdin_data

    def initialize
      @commands = []
    end

    def capture!(*cmd, stdin_data: nil, **)
      @commands << cmd
      @stdin_data = stdin_data unless stdin_data.nil?
      if cmd[0] == "ssh-keygen"
        key = cmd[cmd.index("-f") + 1]
        File.write(key, "private")
        File.write("#{key}.pub", "ssh-ed25519 AAAA\n")
      end
      ""
    end

    def privileged!(*cmd, **opts)
      capture!(*cmd, **opts)
    end

    def spawn_attached(*cmd, **)
      @commands << cmd
      fork { exit 0 }
    end

    def exec!(*cmd, **)
      @commands << cmd
    end

    def spawn_background(*cmd, **)
      @commands << cmd
      socket = cmd.find { |arg| arg.to_s.start_with?("--socket-path=") }
      if socket
        path = socket.split("=", 2)[1]
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "")
      end
      if cmd.first == "ssh" && cmd.include?("-M")
        path = cmd.fetch(cmd.index("-S") + 1)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "")
      end
      fork { exit 0 }
    end
  end

  class ApplyNix < FakeNix
    def evaluate(project)
      info = super
      config = Dir[File.join(project, "user", "*.nix")].first
      return info unless config && File.read(config).include?("candidate")

      info.merge(
        "memoryMB" => 4096,
        "network" => {
          "mode" => "open",
          "allowedDomains" => [],
          "allowedCIDRs" => [],
          "allowedTCPPorts" => [],
          "allowedUDPPorts" => []
        },
        "forwardPorts" => [
          { "bind" => "127.0.0.1", "hostPort" => 4000, "guestPort" => 4001 }
        ],
        "toplevel" => "/nix/store/candidate-system",
        "kernel" => "/nix/store/candidate-kernel/bzImage"
      )
    end
  end

  class SshAwareApplyNix < ApplyNix
    attr_reader :candidate_ssh_key

    def evaluate(project)
      if File.basename(File.dirname(project)).start_with?(".devbox-apply-")
        @candidate_ssh_key = File.read(File.join(File.dirname(project), "ssh", "authorized_key.pub"))
      end
      super
    end
  end

  class ApplyRunner < FakeRunner
    attr_reader :stdin_history

    def initialize
      super
      @stdin_history = []
    end

    def capture!(*cmd, stdin_data: nil, **opts)
      @stdin_history << stdin_data unless stdin_data.nil?
      super
    end
  end

  def around
    previous = ENV.to_h.slice("DEVBOX_STATE", "DEVBOX_CACHE", "DEVBOX_RUNTIME")
    Dir.mktmpdir("devbox-machine-") do |dir|
      @tmpdir = dir
      ENV["DEVBOX_STATE"] = File.join(dir, "state")
      ENV["DEVBOX_CACHE"] = File.join(dir, "cache")
      ENV["DEVBOX_RUNTIME"] = File.join(dir, "runtime")
      @config = File.join(dir, "config.nix")
      File.write(@config, "{ ... }: { devbox.name = \"try\"; }\n")
      super
    end
  ensure
    %w[DEVBOX_STATE DEVBOX_CACHE DEVBOX_RUNTIME].each { |key| ENV.delete(key) }
    previous.each { |key, value| ENV[key] = value }
  end

  def machine
    @runner = FakeRunner.new
    @nix = FakeNix.new
    Devbox::Machine.new(nix: @nix, runner: @runner, io: StringIO.new)
  end

  def test_create_writes_state_under_devbox_state
    created = machine.create(@config)
    state = Devbox::State.load("try")

    assert_equal "stopped", created.status
    assert_equal "try", state.name
    assert_equal File.join(ENV.fetch("DEVBOX_STATE"), "try"), state.dir
    assert_path_exists state.disk
    assert_equal "10.201.0.2", state["ip"]
    assert_equal "devbox0", state["tap"]
    assert_equal "02:db:00:00:00:02", state["mac"]
    assert_equal 30, state["network_prefix"]
    assert_equal "allowlist", state["network"]["mode"]
    assert_equal 3000, state["forward_ports"].first["hostPort"]
    assert_path_exists File.join(state.ssh_dir, "id_ed25519.pub")
    assert_path_exists state.default_nix
    assert_path_exists state.machine_nix
    assert_path_exists File.join(state.project_dir, "npins", "default.nix")
    assert_path_exists File.join(state.project_dir, "user", "config.nix")
    durable = JSON.parse(File.read(File.join(state.dir, "state.json")))
    assert_equal 3, durable["format_version"]
    assert_equal 0, durable["slot"]
    refute durable.key?("tap")
    refute durable.key?("ip")
    refute durable.key?("host_ip")
    refute durable.key?("mac")
    assert_equal 2048, durable["memory_mb"]
    assert_equal 2, durable["vcpus"]
    assert_equal 8, durable["disk_size_gb"]
    refute durable.key?("status")
    assert state.store_dir.start_with?(ENV.fetch("DEVBOX_CACHE"))
    refute state.store_dir.start_with?(ENV.fetch("DEVBOX_STATE"))
  end

  def test_ls_and_status
    machine.create(@config)
    io = StringIO.new
    listed = Devbox::Machine.new(nix: FakeNix.new, runner: FakeRunner.new, io: io)
    listed.ls

    assert_match(/NAME/, io.string)
    assert_match(/try/, io.string)
    assert_match(/stopped/, io.string)
    assert_match(/2048M/, io.string)

    io = StringIO.new
    shown = Devbox::Machine.new(nix: FakeNix.new, runner: FakeRunner.new, io: io)
    shown.status("try")

    assert_match(/memory_mb\s+2048/, io.string)
    assert_match(/vcpus\s+2/, io.string)
    assert_match(/disk_size_gb\s+8/, io.string)
    assert_match(/ip\s+10\.201\.0\.2/, io.string)
  end

  def test_ls_when_empty
    io = StringIO.new
    Devbox::Machine.new(nix: FakeNix.new, runner: FakeRunner.new, io: io).ls

    assert_match(/no VMs/, io.string)
  end

  def test_create_uses_cli_name
    created = machine.create(@config, "custom")

    assert_equal "custom", created.name
    assert_path_exists File.join(ENV.fetch("DEVBOX_STATE"), "custom", "state.json")
    machine_module = File.read(created.machine_nix)
    assert_match(/custom/, machine_module)
  end

  def test_create_requires_a_name
    @nix = Class.new(FakeNix) do
      def evaluate(*)
        super.merge("name" => nil)
      end
    end.new
    m = Devbox::Machine.new(nix: @nix, runner: FakeRunner.new, io: StringIO.new)

    error = assert_raises(Devbox::Error) { m.create(@config) }
    assert_match(/pass a VM name/, error.message)
  end

  def test_ssh_requires_running
    machine.create(@config)

    error = assert_raises(Devbox::Error) { machine.ssh("try") }
    assert_match(/not running/, error.message)
  end

  def test_rm_deletes_vm_dir
    machine.create(@config)
    dir = Devbox::State.load("try").dir

    assert_path_exists dir
    machine.rm("try")
    refute_path_exists dir
    refute_includes Devbox::State.list, "try"
  end

  def test_create_refuses_existing_vm
    machine.create(@config)

    error = assert_raises(Devbox::Error) { machine.create(@config) }
    assert_match(/already exists/, error.message)
  end

  def test_start_without_name_uses_the_only_vm
    machine.create(@config)
    io = StringIO.new
    runner = FakeRunner.new
    m = Devbox::Machine.new(nix: FakeNix.new, runner: runner, io: io)
    m.start(nil)

    assert_match(/started try \(pid \d+\)/, io.string)
    assert_equal "running", Devbox::State.load("try").status
    boot_command = runner.commands.find { |command| command.first == "/bin/cloud-hypervisor" }
    memory_index = boot_command.index("--memory")
    balloon_index = boot_command.index("--balloon")
    assert_equal "size=2048M,shared=on", boot_command.fetch(memory_index + 1)
    assert_equal "size=0,free_page_reporting=on", boot_command.fetch(balloon_index + 1)
    assert_includes boot_command, "path=#{Devbox::State.load("try").persist},image_type=qcow2"
    assert_includes boot_command, "tap=devbox0,mac=02:db:00:00:00:02,num_queues=4"
    ensure_command = runner.commands.find { |command| command[1] == "ensure" }
    assert_equal %w[devbox-net ensure 0 2], ensure_command
    policy_command = runner.commands.find { |command| command[1] == "apply-policy" }
    assert_equal %w[devbox-net apply-policy 0], policy_command
    assert_equal "allowlist", JSON.parse(runner.stdin_data).fetch("mode")
    virtiofsd_command = runner.commands.find { |command| command.first == "/bin/virtiofsd" }
    assert_includes virtiofsd_command, "--readonly"
    assert_includes virtiofsd_command, "--translate-uid=host:#{Process.euid}:0:1"
    assert_includes virtiofsd_command, "--translate-gid=host:#{Process.egid}:0:1"
  end

  def test_start_with_one_vcpu_uses_a_single_queue_tap
    nix = Class.new(FakeNix) do
      def evaluate(*)
        super.merge("vcpus" => 1)
      end
    end.new
    runner = FakeRunner.new
    m = Devbox::Machine.new(nix: nix, runner: runner, io: StringIO.new)
    m.create(@config)
    m.start("try")

    boot_command = runner.commands.find { |command| command.first == "/bin/cloud-hypervisor" }
    assert_includes boot_command, "tap=devbox0,mac=02:db:00:00:00:02,num_queues=2"
    assert_includes runner.commands, %w[devbox-net ensure 0 1]
  end

  def test_start_uses_one_control_master_for_all_declarative_forwards
    nix = Class.new(FakeNix) do
      def evaluate(*)
        super.merge(
          "forwardPorts" => [
            { "bind" => "127.0.0.1", "hostPort" => 3000, "guestPort" => 3001 },
            { "bind" => "127.0.0.1", "hostPort" => 8080, "guestPort" => 80 }
          ]
        )
      end
    end.new
    runner = FakeRunner.new
    m = Devbox::Machine.new(nix: nix, runner: runner, io: StringIO.new)
    m.create(@config)

    m.start("try")

    state = Devbox::State.load("try")
    masters = runner.commands.select { |command| command.first == "ssh" && command.include?("-M") }
    assert_equal 1, masters.length
    command = masters.first
    assert_includes command, "ExitOnForwardFailure=yes"
    assert_includes command, "127.0.0.1:3000:127.0.0.1:3001"
    assert_includes command, "127.0.0.1:8080:127.0.0.1:80"
    assert_equal state.forward_control_socket, command.fetch(command.index("-S") + 1)
    assert state["forward_pid"]
    assert_path_exists state.forward_control_socket
  end

  def test_declarative_forward_failure_rolls_back_running_vm
    runner = Class.new(FakeRunner) do
      def spawn_background(*cmd, **opts)
        return super unless cmd.first == "ssh" && cmd.include?("-M")

        @commands << cmd
        999_999_999
      end
    end.new
    m = Devbox::Machine.new(nix: FakeNix.new, runner: runner, io: StringIO.new)
    m.create(@config)

    error = assert_raises(Devbox::Error) { m.start("try") }

    assert_match(/host port may already be in use/, error.message)
    state = Devbox::State.load("try")
    assert_equal "stopped", state.status
    assert_nil state["pid"]
    assert_nil state["forward_pid"]
    assert_includes runner.commands, %w[devbox-net delete 0]
    shutdown = runner.commands.index { |command| command.include?("http://localhost/api/v1/vm.shutdown") }
    delete = runner.commands.index(%w[devbox-net delete 0])
    assert_operator shutdown, :<, delete
  end

  def test_stop_closes_declarative_forwards_before_guest_shutdown
    machine.create(@config)
    machine.start("try")
    state = Devbox::State.load("try")

    machine.stop("try")

    exit_command = @runner.commands.index do |command|
      command.first == "ssh" && command.each_cons(2).any? { |option, value| option == "-O" && value == "exit" }
    end
    shutdown = @runner.commands.index { |command| command.include?("http://localhost/api/v1/vm.shutdown") }
    assert_operator exit_command, :<, shutdown
    refute_path_exists state.forward_control_socket
    assert_nil Devbox::State.load("try")["forward_pid"]
  end

  def test_stop_discovers_forward_process_when_runtime_pid_is_lost
    m = machine
    created = m.create(@config)
    FileUtils.mkdir_p(created.runtime_dir)
    File.write(created.forward_control_socket, "")
    sleeper = fork { Kernel.sleep(30) }

    m.stub(:discover_forward_pid, sleeper) do
      m.stop("try")
    end

    refute m.send(:process_alive?, sleeper)
    refute_path_exists created.forward_control_socket
    assert(@runner.commands.any? do |command|
      command.first == "ssh" && command.include?(created.forward_control_socket) && command.include?("exit")
    end)
  ensure
    begin
      Process.kill("KILL", sleeper) if sleeper && m&.send(:process_alive?, sleeper)
      Process.wait(sleeper) if sleeper
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  def test_attached_forward_uses_exact_localhost_arguments
    created = machine.create(@config)
    created["status"] = "running"
    created["pid"] = Process.pid
    created.save

    machine.forward("try", "8080:3000")

    command = @runner.commands.last
    assert_equal "ssh", command.first
    assert_includes command, "ExitOnForwardFailure=yes"
    assert_equal "127.0.0.1:8080:127.0.0.1:3000", command.fetch(command.index("-L") + 1)
    assert_equal "dev@10.201.0.2", command.last
  end

  def test_attached_forward_defaults_guest_port_and_rejects_hostile_input
    created = machine.create(@config)
    created["status"] = "running"
    created["pid"] = Process.pid
    created.save

    machine.forward("try", "3000")
    assert_equal "127.0.0.1:3000:127.0.0.1:3000", @runner.commands.last.fetch(@runner.commands.last.index("-L") + 1)

    ["0", "65536", "3000:0", "127.0.0.1:3000", "3000:4000:5000", "3000;id"].each do |mapping|
      assert_raises(Devbox::Error) { machine.forward("try", mapping) }
    end
  end

  def test_network_policy_failure_deletes_privileged_runtime_before_starting_services
    runner = Class.new(FakeRunner) do
      def privileged!(*cmd, **opts)
        capture!(*cmd, **opts)
        raise Devbox::Error, "policy rejected" if cmd[1] == "apply-policy"

        ""
      end
    end.new
    m = Devbox::Machine.new(nix: FakeNix.new, runner: runner, io: StringIO.new)
    m.create(@config)

    error = assert_raises(Devbox::Error) { m.start("try") }

    assert_match(/policy rejected/, error.message)
    network_commands = runner.commands.select { |command| command.first == "devbox-net" }
    assert_equal(%w[ensure apply-policy delete], network_commands.map { |command| command[1] })
    refute(runner.commands.any? { |command| command.first == "/bin/virtiofsd" })
    assert_equal "stopped", Devbox::State.load("try").status
  end

  def test_cloud_hypervisor_startup_failure_deletes_policy_dns_and_tap
    runner = Class.new(FakeRunner) do
      def spawn_background(*cmd, **opts)
        if cmd.first == "/bin/cloud-hypervisor"
          @commands << cmd
          999_999_999
        else
          super
        end
      end
    end.new
    m = Devbox::Machine.new(nix: FakeNix.new, runner: runner, io: StringIO.new)
    m.create(@config)

    error = assert_raises(Devbox::Error) { m.start("try") }

    assert_match(/cloud-hypervisor exited during startup/, error.message)
    network_commands = runner.commands.select { |command| command.first == "devbox-net" }
    assert_equal(%w[ensure apply-policy delete], network_commands.map { |command| command[1] })
    state = Devbox::State.load("try")
    assert_equal "stopped", state.status
    assert_nil state["pid"]
    assert_nil state["virtiofsd_pid"]
  end

  def test_rm_calls_helper_delete_even_when_tap_is_not_visible
    machine.create(@config)

    machine.rm("try")

    assert_includes @runner.commands, %w[devbox-net delete 0]
  end

  def test_stop_reconciles_stale_privileged_network_for_already_stopped_vm
    machine.create(@config)

    machine.stop("try")

    assert_includes @runner.commands, %w[devbox-net delete 0]
    assert_equal "stopped", Devbox::State.load("try").status
  end

  def test_packaged_helper_path_is_passed_to_privileged_runner_verbatim
    machine.create(@config)
    previous = ENV.fetch("DEVBOX_NET_HELPER", nil)
    ENV["DEVBOX_NET_HELPER"] = "/nix/store/helper/bin/devbox-net"

    machine.start("try")

    network_commands = @runner.commands.select { |command| command.first == "/nix/store/helper/bin/devbox-net" }
    assert_equal(%w[ensure apply-policy], network_commands.map { |command| command[1] })
  ensure
    ENV["DEVBOX_NET_HELPER"] = previous
  end

  def test_start_refuses_a_disk_locked_by_an_untracked_instance
    created = machine.create(@config)
    runner = FakeRunner.new
    m = Devbox::Machine.new(nix: FakeNix.new, runner: runner, io: StringIO.new)

    File.open(created.persist, "r+") do |disk|
      lock = [Fcntl::F_WRLCK, IO::SEEK_SET, 0, 0, 0].pack(Devbox::Hypervisor::FLOCK_FORMAT)
      disk.fcntl(Devbox::Hypervisor::F_OFD_SETLK, lock)
      error = assert_raises(Devbox::Error) { m.start("try") }

      assert_match(/disk is already in use/, error.message)
      assert_empty runner.commands
    end
  end

  def test_start_rotates_previous_logs
    created = machine.create(@config)
    FileUtils.mkdir_p(File.dirname(created.hypervisor_log))
    File.write(created.hypervisor_log, "old hypervisor log\n")
    File.write(created.virtiofs_log, "old virtiofs log\n")

    machine.start("try")

    assert_equal "old hypervisor log\n", File.read("#{created.hypervisor_log}.previous")
    assert_equal "old virtiofs log\n", File.read("#{created.virtiofs_log}.previous")
  end

  def test_shell_exec_console_and_logs
    created = machine.create(@config)
    created["status"] = "running"
    created["pid"] = Process.pid
    created.save
    File.write(created.console_socket, "")
    FileUtils.mkdir_p(File.dirname(created.hypervisor_log))
    File.write(created.hypervisor_log, "hypervisor output\n")

    machine.shell("try")
    assert_includes @runner.commands.last, "-t"
    assert_equal "dev@10.201.0.2", @runner.commands.last.last

    machine.exec("try", %w[systemctl status nginx])
    exec_command = @runner.commands.last
    assert_includes exec_command, "-n"
    assert_includes exec_command, "-T"
    assert_equal "systemctl status nginx", exec_command.last

    machine.exec("try", ["bash"], interactive: true, tty: true)
    interactive_command = @runner.commands.last
    refute_includes interactive_command, "-n"
    assert_includes interactive_command, "-t"

    machine.console("try")
    assert_equal "socat", @runner.commands.last.first
    assert_includes @runner.commands.last, "UNIX-CONNECT:#{created.console_socket}"

    io = StringIO.new
    Devbox::Machine.new(nix: FakeNix.new, runner: @runner, io: io).logs("try")
    assert_equal "hypervisor output\n", io.string
  end

  def test_exec_preserves_remote_argument_boundaries
    created = machine.create(@config)
    created["status"] = "running"
    created["pid"] = Process.pid
    created.save

    machine.exec("try", ["sh", "-c", "cat > /tmp/input"])

    assert_equal "sh -c cat\\ \\>\\ /tmp/input", @runner.commands.last.last
  end

  def test_exec_requires_a_command
    created = machine.create(@config)
    created["status"] = "running"
    created["pid"] = Process.pid
    created.save

    error = assert_raises(Devbox::Error) { machine.exec("try", []) }
    assert_match(/pass a command/, error.message)
  end

  def test_apply_on_stopped_updates_store
    machine.create(@config)
    io = StringIO.new
    m = Devbox::Machine.new(nix: FakeNix.new, runner: FakeRunner.new, io: io)
    m.apply(@config)

    assert_match(/not running/, io.string)
    assert_match(/applied/, io.string)
    refute(m.instance_variable_get(:@runner).commands.any? { |command| command.first == "devbox-net" })
  end

  def test_stopped_apply_commits_candidate_project_and_spec_without_materializing_runtime
    m = Devbox::Machine.new(nix: ApplyNix.new, runner: FakeRunner.new, io: StringIO.new)
    created = m.create(@config)
    FileUtils.rm_rf(created.build_dir)
    File.write(@config, "{ ... }: { # candidate\n devbox.name = \"try\"; }\n")

    m.apply(@config, "try")

    state = Devbox::State.load("try")
    assert_equal 4096, state["memory_mb"]
    assert_equal "open", state["network"]["mode"]
    assert_equal 4000, state["forward_ports"].first["hostPort"]
    assert_includes File.read(File.join(state.project_dir, "user", "config.nix")), "candidate"
    refute(m.instance_variable_get(:@runner).commands.any? { |command| command.first == "devbox-net" })
  end

  def test_apply_stages_durable_public_key_for_candidate_evaluation
    nix = SshAwareApplyNix.new
    m = Devbox::Machine.new(nix: nix, runner: FakeRunner.new, io: StringIO.new)
    created = m.create(@config)
    durable_key = File.read(File.join(created.ssh_dir, "authorized_key.pub"))

    m.apply(@config, "try")

    assert_equal durable_key, nix.candidate_ssh_key
    assert_includes File.read(Devbox::State.load("try").machine_nix), "../ssh/authorized_key.pub"
  end

  def test_apply_preparation_failure_keeps_durable_project_and_state
    nix = Class.new(ApplyNix) do
      def build_system(project:, **)
        config = Dir[File.join(project, "user", "*.nix")].first
        raise Devbox::Error, "candidate build failed" if File.read(config).include?("candidate")
      end
    end.new
    m = Devbox::Machine.new(nix: nix, runner: FakeRunner.new, io: StringIO.new)
    m.create(@config)
    before = File.read(Devbox::State.path_for("try"))
    File.write(@config, "{ ... }: { # candidate\n devbox.name = \"try\"; }\n")

    assert_raises(Devbox::Error) { m.apply(@config, "try") }

    state = Devbox::State.load("try")
    assert_equal before, File.read(Devbox::State.path_for("try"))
    refute_includes File.read(File.join(state.project_dir, "user", "config.nix")), "candidate"
    assert_equal "allowlist", state["network"]["mode"]
  end

  def test_apply_runs_switch_script_as_root_over_stdin
    created = machine.create(@config)
    created["status"] = "running"
    created["pid"] = Process.pid
    created.save

    machine.apply(@config, "try")

    switch_command = @runner.commands.last
    assert_equal "ssh", switch_command.first
    assert_equal "sudo bash -s", switch_command.last
    assert_includes @runner.stdin_data, "switch-to-configuration switch"
    refute_includes @runner.stdin_data, "nix-store --load-db"
    refute(switch_command.any? { |argument| argument.include?("switch-to-configuration") })
  end

  def test_live_apply_orders_policy_activation_and_forward_diff_before_commit
    runner = ApplyRunner.new
    m = Devbox::Machine.new(nix: ApplyNix.new, runner: runner, io: StringIO.new)
    created = m.create(@config)
    created["status"] = "running"
    created["pid"] = Process.pid
    created["forward_pid"] = Process.pid
    created.save
    FileUtils.mkdir_p(created.runtime_dir)
    File.write(created.forward_control_socket, "")
    File.write(@config, "{ ... }: { # candidate\n devbox.name = \"try\"; }\n")

    m.apply(@config, "try")

    policy = runner.commands.index { |command| command[0, 2] == %w[devbox-net apply-policy] }
    activation = runner.commands.index { |command| command.first == "ssh" && command.last == "sudo bash -s" }
    cancel = runner.commands.index { |command| command.include?("cancel") }
    add = runner.commands.index { |command| command.include?("forward") }
    assert_operator policy, :<, activation
    assert_operator activation, :<, cancel
    assert_operator cancel, :<, add
    assert_includes runner.stdin_history, JSON.generate(Devbox::State.load("try")["network"])
    candidate_switch = "/nix/store/candidate-system/bin/switch-to-configuration"
    assert(runner.stdin_history.any? { |data| data.include?(candidate_switch) })
    assert_equal 4000, Devbox::State.load("try")["forward_ports"].first["hostPort"]
  end

  def test_live_apply_forward_failure_rolls_back_guest_policy_and_forward_diff
    runner = Class.new(ApplyRunner) do
      def capture!(*cmd, **opts)
        if cmd.include?("forward") && cmd.include?("127.0.0.1:4000:127.0.0.1:4001")
          @commands << cmd
          raise Devbox::Error, "new port is occupied"
        end
        super
      end
    end.new
    m = Devbox::Machine.new(nix: ApplyNix.new, runner: runner, io: StringIO.new)
    created = m.create(@config)
    created["status"] = "running"
    created["pid"] = Process.pid
    created["forward_pid"] = Process.pid
    created.save
    FileUtils.mkdir_p(created.runtime_dir)
    File.write(created.forward_control_socket, "")
    File.write(@config, "{ ... }: { # candidate\n devbox.name = \"try\"; }\n")

    error = assert_raises(Devbox::Error) { m.apply(@config, "try") }

    assert_match(/new port is occupied/, error.message)
    switches = runner.stdin_history.grep(/switch-to-configuration/)
    assert_equal 2, switches.length
    assert_includes switches.first, "/nix/store/candidate-system/bin/switch-to-configuration"
    assert_includes switches.last, "/nix/store/fake-system/bin/switch-to-configuration"
    policies = runner.stdin_history.filter_map do |data|
      parsed = JSON.parse(data)
      parsed["mode"] if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end
    assert_equal %w[open allowlist], policies.last(2)
    restored = runner.commands.select { |command| command.include?("forward") }
    assert(restored.any? { |command| command.include?("127.0.0.1:3000:127.0.0.1:3000") })
    state = Devbox::State.load("try")
    assert_equal "allowlist", state["network"]["mode"]
    refute_includes File.read(File.join(state.project_dir, "user", "config.nix")), "candidate"
  end
end

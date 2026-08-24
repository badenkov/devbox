# frozen_string_literal: true

require "fcntl"
require "fileutils"
require "json"

module Devbox
  class Hypervisor
    # Linux open-file-description locks. Cloud Hypervisor uses these instead
    # of flock(2), so Ruby's File#flock cannot detect an active disk lock.
    F_OFD_SETLK = 37
    FLOCK_FORMAT = "s!s!x4q!q!i!x4"

    def initialize(state, runner: Runner.new, net_helper: ENV.fetch("DEVBOX_NET_HELPER", "devbox-net"))
      @state = state
      @runner = runner
      @net_helper = net_helper
    end

    def ensure_tap
      @runner.privileged!(@net_helper, "ensure", Integer(@state["slot"]).to_s, network_queue_pairs.to_s)
    end

    def apply_network_policy
      policy = JSON.generate(@state["network"] || {})
      @runner.privileged!(@net_helper, "apply-policy", Integer(@state["slot"]).to_s, stdin_data: policy)
    end

    def teardown_tap
      @runner.privileged!(@net_helper, "delete", Integer(@state["slot"]).to_s)
    end

    def start_virtiofsd
      stop_virtiofsd
      FileUtils.rm_f(@state.virtiofs_socket)
      FileUtils.mkdir_p(@state.store_dir)
      FileUtils.mkdir_p(@state.runtime_dir, mode: 0o700)
      pid = @runner.spawn_background(
        @state["virtiofsd"],
        "--socket-path=#{@state.virtiofs_socket}",
        "--shared-dir=#{@state.store_dir}",
        "--readonly",
        "--translate-uid=host:#{Process.euid}:0:1",
        "--translate-gid=host:#{Process.egid}:0:1",
        "--cache=auto",
        "--sandbox=none",
        "--thread-pool-size=4",
        log: @state.virtiofs_log
      )
      wait_for_socket(@state.virtiofs_socket)
      pid
    end

    def stop_virtiofsd
      pid = @state["virtiofsd_pid"]
      wait_until_dead(pid, timeout: 5) if running_pid?(pid)
      FileUtils.rm_f(@state.virtiofs_socket)
    end

    def boot
      spawn_ch(*boot_args)
    end

    def disk_in_use?
      File.open(@state.persist, "r+") do |disk|
        disk.fcntl(F_OFD_SETLK, flock(Fcntl::F_WRLCK))
        disk.fcntl(F_OFD_SETLK, flock(Fcntl::F_UNLCK))
        false
      end
    rescue Errno::EACCES, Errno::EAGAIN, Errno::EWOULDBLOCK
      true
    end

    def discover_vmm_pid
      find_process("cloud-hypervisor") do |args|
        args.any? { |arg| arg.include?("path=#{@state.persist}") }
      end
    end

    def discover_virtiofsd_pid
      roots = ["#{@state.dir}/", "#{@state.cache_dir}/", "#{@state.runtime_dir}/"]
      find_process("virtiofsd") do |args|
        args.any? { |arg| roots.any? { |root| arg.include?(root) } }
      end
    end

    def terminate(pid, timeout: 5)
      return unless running_pid?(pid)

      Process.kill("TERM", pid)
      deadline = Time.now + timeout
      loop do
        begin
          return if Process.wait(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          nil
        end
        return unless running_pid?(pid)
        break if Time.now >= deadline

        Kernel.sleep(0.05)
      end
      Process.kill("KILL", pid) if running_pid?(pid)
    rescue Errno::ESRCH
      nil
    end

    def rotate_logs
      [@state.hypervisor_log, @state.virtiofs_log].each do |path|
        next unless File.file?(path)

        previous = "#{path}.previous"
        FileUtils.rm_f(previous)
        FileUtils.mv(path, previous)
      end
    end

    def api!(endpoint, method: "PUT", body: nil)
      cmd = [
        "curl", "-sS", "-f", "--unix-socket", @state.api_socket,
        "-X", method, "http://localhost/api/v1/#{endpoint}"
      ]
      cmd.push("-H", "Content-Type: application/json", "-d", JSON.generate(body)) if body
      @runner.capture!(*cmd)
    end

    def shutdown_guest
      api!("vm.shutdown")
    end

    def running_pid?(pid)
      return false if pid.nil?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def wait_until_dead(pid, timeout: 30)
      return if pid.nil?

      deadline = Time.now + timeout
      loop do
        begin
          return if Process.wait(pid, Process::WNOHANG)
        rescue Errno::ECHILD
          nil
        end
        return unless running_pid?(pid)
        break if Time.now >= deadline

        Kernel.sleep(0.05)
      end
      Process.kill("TERM", pid)
      Kernel.sleep(0.2)
      Process.kill("KILL", pid) if running_pid?(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def boot_args
      queues = network_queue_pairs * 2
      [
        @state["ch"],
        "--api-socket", "path=#{@state.api_socket}",
        "--cpus", "boot=#{@state["vcpus"]}",
        "--memory", "size=#{@state["memory_mb"]}M,shared=on",
        "--balloon", "size=0,free_page_reporting=on",
        "--kernel", @state["kernel"],
        "--initramfs", @state["initrd"],
        "--cmdline", @state["cmdline"],
        "--disk", "path=#{@state.persist},image_type=qcow2",
        "--fs", "tag=nix-store,socket=#{@state.virtiofs_socket}",
        "--net", "tap=#{@state["tap"]},mac=#{@state["mac"]},num_queues=#{queues}",
        "--console", "off",
        "--serial", "socket=#{@state.console_socket}"
      ]
    end

    private

    def flock(type)
      [type, IO::SEEK_SET, 0, 0, 0].pack(FLOCK_FORMAT)
    end

    def find_process(executable)
      Dir.glob("/proc/[0-9]*/cmdline").each do |path|
        args = File.binread(path).split("\0")
        next unless File.basename(args.first.to_s).include?(executable)
        next unless yield(args)

        return File.basename(File.dirname(path)).to_i
      rescue Errno::EACCES, Errno::ENOENT, Errno::ESRCH
        next
      end
      nil
    end

    def network_queue_pairs
      [@state["vcpus"].to_i, 1].max
    end

    def spawn_ch(*args)
      FileUtils.rm_f(@state.api_socket)
      FileUtils.rm_f(@state.console_socket)
      @runner.spawn_background(*args, log: @state.hypervisor_log)
    end

    def wait_for_socket(path, timeout: 5)
      deadline = Time.now + timeout
      Kernel.sleep(0.05) until File.exist?(path) || Time.now >= deadline
      return if File.exist?(path)

      raise Error, "virtiofsd did not create #{path}"
    end
  end
end

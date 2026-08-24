# frozen_string_literal: true

require "fileutils"
require "open3"

module Devbox
  class Runner
    def initialize(env: ENV)
      @env = env
    end

    def capture!(*cmd, chdir: nil, extra_env: {}, stdin_data: nil)
      opts = spawn_opts(chdir: chdir)
      opts[:stdin_data] = stdin_data unless stdin_data.nil?
      stdout, stderr, status = Open3.capture3(env(extra_env), *cmd, **opts)
      raise Error, command_error(cmd, stderr, stdout, status) unless status.success?

      stdout
    end

    def spawn_attached(*cmd, extra_env: {})
      Process.spawn(env(extra_env), *cmd, in: $stdin, out: $stdout, err: $stderr)
    end

    def exec!(*cmd, extra_env: {})
      Process.exec(env(extra_env), *cmd)
    end

    def spawn_background(*cmd, extra_env: {}, log: File::NULL)
      unless log == File::NULL
        dir = File.dirname(log)
        FileUtils.mkdir_p(dir) unless dir == "."
      end
      File.open(log, "a") do |log_file|
        pid = Process.spawn(
          env(extra_env),
          *cmd,
          in: :close,
          out: log_file,
          err: log_file,
          pgroup: true
        )
        Process.detach(pid)
        pid
      end
    end

    def privileged!(*cmd, chdir: nil, stdin_data: nil)
      resolved = resolve_command(cmd)
      return capture!(*resolved, chdir: chdir, stdin_data: stdin_data) if Process.euid.zero?

      begin
        capture!(*resolved, chdir: chdir, stdin_data: stdin_data)
      rescue Error
        begin
          capture!("sudo", "-n", "--", *resolved, chdir: chdir, stdin_data: stdin_data)
        rescue Error
          warn_sudo(resolved)
          status = run_tty("sudo", "--", *resolved, chdir: chdir, stdin_data: stdin_data)
          raise Error, "sudo #{resolved.join(" ")} failed (exit #{status.exitstatus})" unless status.success?

          ""
        end
      end
    end

    private

    def env(extra_env)
      @env.to_h.merge(extra_env).compact
    end

    def spawn_opts(chdir: nil)
      opts = {}
      opts[:chdir] = chdir unless chdir.nil?
      opts
    end

    def resolve_command(cmd)
      name = cmd.first
      return cmd if name.nil? || name.include?(File::SEPARATOR)

      found = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find do |path|
        File.executable?(path)
      end
      raise Error, "command not found: #{name}" unless found

      [found, *cmd.drop(1)]
    end

    def run_tty(*cmd, chdir: nil, stdin_data: nil)
      input = $stdin
      reader = writer = nil
      unless stdin_data.nil?
        reader, writer = IO.pipe
        input = reader
      end
      opts = { in: input, out: $stdout, err: $stderr }
      opts[:chdir] = chdir unless chdir.nil?
      pid = Process.spawn(env({}), *cmd, **opts)
      reader&.close
      unless writer.nil?
        begin
          writer.write(stdin_data)
        rescue Errno::EPIPE
          nil
        end
        writer.close
      end
      Process.wait(pid)
      Process.last_status
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
    end

    def warn_sudo(cmd)
      warn "devbox: need root for #{cmd.first} (host network setup); prompting sudo"
    end

    def command_error(cmd, stderr, stdout, status)
      detail = [stderr, stdout].map(&:strip).reject(&:empty?).join("\n")
      detail = "exit #{status.exitstatus}" if detail.empty?
      "#{cmd.join(" ")} failed: #{detail}"
    end
  end
end

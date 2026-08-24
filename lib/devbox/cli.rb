# frozen_string_literal: true

class Devbox::CLI < Thor
  def self.exit_on_failure?
    true
  end

  def self.basename
    "devbox"
  end

  remove_command :tree

  desc "version", "Print version"
  def version
    say "devbox #{Devbox::VERSION}"
  end

  desc "create CONFIG [NAME]", "Create a VM from a NixOS module"
  def create(config, name = nil)
    action { Devbox::Machine.create(config, name) }
  end

  desc "start [NAME]", "Start a VM in the background"
  def start(name = nil)
    action { Devbox::Machine.start(name) }
  end

  desc "stop [NAME]", "Shut the VM down"
  def stop(name = nil)
    action { Devbox::Machine.stop(name) }
  end

  desc "apply CONFIG [NAME]", "Apply a NixOS module to a running VM"
  def apply(config, name = nil)
    action { Devbox::Machine.apply(config, name) }
  end

  desc "ls", "List VMs"
  def ls
    action { Devbox::Machine.ls }
  end

  desc "status NAME", "Show VM status"
  def status(name)
    action { Devbox::Machine.status(name) }
  end

  desc "ssh [NAME]", "SSH into a running VM"
  def ssh(name = nil, *cmd)
    action { Devbox::Machine.ssh(name, cmd) }
  end

  map "shell" => :open_shell
  desc "shell [NAME]", "Open an interactive login shell in a running VM"
  def open_shell(name = nil)
    action { Devbox::Machine.shell(name) }
  end

  desc "exec NAME -- COMMAND...", "Run a command in a running VM"
  option :interactive, aliases: "-i", type: :boolean, default: false, desc: "Keep stdin open"
  option :tty, aliases: "-t", type: :boolean, default: false, desc: "Allocate a pseudo-TTY"
  def exec(name, *command)
    action do
      Devbox::Machine.exec(name, command, interactive: options[:interactive], tty: options[:tty])
    end
  end

  desc "forward NAME HOST[:GUEST]", "Forward a localhost port to a running VM"
  def forward(name, mapping)
    action { Devbox::Machine.forward(name, mapping) }
  end

  desc "console [NAME]", "Attach to the VM serial console"
  def console(name = nil)
    action { Devbox::Machine.console(name) }
  end

  desc "logs [NAME]", "Show Cloud Hypervisor logs"
  option :follow, aliases: "-f", type: :boolean, default: false, desc: "Follow log output"
  def logs(name = nil)
    action { Devbox::Machine.logs(name, follow: options[:follow]) }
  end

  desc "rm NAME", "Delete a VM and its state"
  def rm(name)
    action { Devbox::Machine.rm(name) }
  end

  no_commands do
    def action
      yield
    rescue Devbox::Error => e
      raise Thor::Error, e.message
    end
  end
end

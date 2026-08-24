# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"

module Devbox
  class Nix
    SOURCE_EXCLUDES = %w[.git .direnv npins result tmp].freeze

    def initialize(runner: Runner.new)
      @runner = runner
    end

    def current_system
      cpu = RbConfig::CONFIG["host_cpu"]
      case cpu
      when "x86_64", "amd64" then "x86_64-linux"
      when "aarch64", "arm64" then "aarch64-linux"
      else
        raise Error, "unsupported host cpu #{cpu.inspect}"
      end
    end

    def prepare_project(config_path, project_dir, preserve_npins: false)
      config_path = File.expand_path(config_path)
      source_dir = File.dirname(config_path)
      user_dir = File.join(project_dir, "user")
      devbox_dir = File.join(project_dir, "devbox")
      FileUtils.mkdir_p(project_dir)
      FileUtils.rm_rf(user_dir)
      FileUtils.mkdir_p(user_dir)
      Dir.children(source_dir).each do |entry|
        next if SOURCE_EXCLUDES.include?(entry) || entry.start_with?("result-")

        FileUtils.cp_r(File.join(source_dir, entry), user_dir, preserve: true)
      end
      FileUtils.rm_rf(devbox_dir)
      FileUtils.mkdir_p(devbox_dir)
      FileUtils.cp(Paths.guest_module, File.join(devbox_dir, "guest.nix"))
      FileUtils.cp_r(File.join(Paths.root, "nix", "guest"), devbox_dir, preserve: true)

      npins = File.join(project_dir, "npins")
      source_npins = File.join(source_dir, "npins")
      unless preserve_npins && File.file?(File.join(npins, "default.nix"))
        FileUtils.rm_rf(npins)
        FileUtils.cp_r(source_npins, npins, preserve: true) if File.file?(File.join(source_npins, "default.nix"))
      end
      ensure_npins(project_dir)

      machine = File.join(project_dir, "machine.nix")
      File.write(machine, "{ ... }: {}\n") unless File.file?(machine)
      config_name = File.basename(config_path)
      File.write(File.join(project_dir, "default.nix"), <<~NIX)
        { ... }: {
          imports = [
            ./devbox/guest.nix
            ./user/#{config_name}
            ./machine.nix
          ];
        }
      NIX
      project_dir
    end

    def ensure_npins(project_dir)
      project_dir = File.expand_path(project_dir)
      npins = File.join(project_dir, "npins")
      return if File.file?(File.join(npins, "default.nix"))

      @runner.capture!("npins", "init", "--bare", chdir: project_dir)
      @runner.capture!("npins", "add", "github", "NixOS", "nixpkgs", "--branch", "nixos-unstable",
                       chdir: project_dir)
    end

    def nixpkgs_path(project_dir)
      npins = File.join(File.expand_path(project_dir), "npins")
      @runner.capture!("nix-instantiate", "--eval", "--raw", "--expr",
                       "\"${(import #{nix_path(npins)}).nixpkgs}\"").strip
    end

    def evaluate(project_dir)
      ensure_npins(project_dir)
      json = @runner.capture!(
        "nix-instantiate", "--eval", "--strict", "--json", "--read-write-mode",
        "--argstr", "system", current_system,
        "--argstr", "project", File.expand_path(project_dir),
        Paths.eval_info
      )
      JSON.parse(json)
    end

    def build_system(project:, nixpkgs:, gc_root_dir:)
      FileUtils.mkdir_p(gc_root_dir)
      nixos = File.join(nixpkgs, "nixos")
      common = ["-I", "nixpkgs=#{nixpkgs}", "-I", "nixos-config=#{File.join(project, "default.nix")}", nixos]
      @runner.capture!(
        "nix-build", "--out-link", File.join(gc_root_dir, "toplevel"),
        *common, "-A", "config.system.build.toplevel"
      )
    end

    def closure_info(nixpkgs:, toplevel:, gc_root_dir:)
      link = File.join(gc_root_dir, "closure-info")
      expr = <<~NIX.chomp
        (import #{nix_path(Paths.closure_info)} {
          nixpkgs = #{nix_path(nixpkgs)};
          system = #{JSON.generate(current_system)};
          toplevel = #{nix_path(toplevel)};
        })
      NIX
      @runner.capture!("nix-build", "--out-link", link, "-E", expr)
      File.realpath(link)
    end

    def populate_store(store_root:, gc_root_dir:, toplevel:, extra: [], closure_info: nil)
      FileUtils.mkdir_p(File.join(store_root, "nix", "store"))
      FileUtils.mkdir_p(gc_root_dir)
      paths = [toplevel, *extra]
      paths << closure_info if closure_info
      unless reflink_copy(store_root, paths, closure_info)
        @runner.capture!("nix", "copy", "--no-check-sigs", "--to", store_root, *paths)
      end
      dest = File.join(store_root, "nix", "store", File.basename(toplevel))
      raise Error, "failed to populate VM store with #{toplevel}" unless File.exist?(dest)

      root = File.join(gc_root_dir, "system")
      FileUtils.rm_f(root)
      FileUtils.ln_s(dest, root)
    end

    def create_persist(dest, size_gb)
      FileUtils.mkdir_p(File.dirname(dest))
      raw = "#{dest}.raw"
      bytes = Integer(size_gb) * 1024 * 1024 * 1024
      File.write(raw, "")
      File.truncate(raw, bytes)
      @runner.capture!("mkfs.ext4", "-F", "-L", "persist", raw)
      FileUtils.rm_f(dest)
      @runner.capture!("qemu-img", "convert", "-O", "qcow2", raw, dest)
      FileUtils.rm_f(raw)
      dest
    end

    def realize_tools(nixpkgs:, gc_root_dir:)
      FileUtils.mkdir_p(gc_root_dir)
      tools = <<~NIX.chomp
        (import #{nix_path(Paths.tools_nix)} {
          nixpkgs = #{nix_path(nixpkgs)};
          system = #{JSON.generate(current_system)};
        })
      NIX
      ch_root = File.join(gc_root_dir, "cloud-hypervisor")
      virtiofsd_root = File.join(gc_root_dir, "virtiofsd")
      @runner.capture!("nix-build", "--out-link", ch_root, "-E", "#{tools}.cloud-hypervisor")
      @runner.capture!("nix-build", "--out-link", virtiofsd_root, "-E", "#{tools}.virtiofsd")
      {
        "cloudHypervisor" => File.join(ch_root, "bin", "cloud-hypervisor"),
        "virtiofsd" => File.join(virtiofsd_root, "bin", "virtiofsd")
      }
    end

    def nix_path(path)
      "(/. + #{JSON.generate(File.expand_path(path))})"
    end

    def cmdline(info)
      params = Array(info["kernelParams"])
      params += ["init=#{info.fetch("toplevel")}/init"] unless params.any? { |p| p.start_with?("init=") }
      params.join(" ")
    end

    private

    def reflink_copy(store_root, roots, closure_info)
      dest_store = File.join(store_root, "nix", "store")
      requisites = @runner.capture!("nix-store", "-qR", *roots).split
      requisites.each do |src|
        dest = File.join(dest_store, File.basename(src))
        next if File.exist?(dest)

        @runner.capture!("cp", "-a", "--reflink=always", src, dest)
      end
      db =
        if closure_info && File.file?(File.join(closure_info, "registration"))
          File.read(File.join(closure_info, "registration"))
        else
          @runner.capture!("nix-store", "--dump-db", *requisites)
        end
      @runner.capture!("nix-store", "--store", store_root, "--load-db", stdin_data: db)
      true
    rescue Error
      false
    end
  end
end

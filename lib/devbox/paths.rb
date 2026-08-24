# frozen_string_literal: true

require "tmpdir"

module Devbox
  module Paths
    APP_NAME = "devbox"

    module_function

    def root
      explicit = ENV.fetch("DEVBOX_ROOT", nil)
      return File.expand_path(explicit) unless blank?(explicit)

      File.expand_path("../..", __dir__)
    end

    def guest_module
      File.join(root, "nix", "guest.nix")
    end

    def eval_info
      File.join(root, "nix", "lib", "eval-info.nix")
    end

    def tools_nix
      File.join(root, "nix", "lib", "tools.nix")
    end

    def closure_info
      File.join(root, "nix", "lib", "closure-info.nix")
    end

    def state_root
      explicit = ENV.fetch("DEVBOX_STATE", nil)
      return File.expand_path(explicit) unless blank?(explicit)

      File.join(xdg_state_home, APP_NAME)
    end

    def cache_root
      explicit = ENV.fetch("DEVBOX_CACHE", nil)
      return File.expand_path(explicit) unless blank?(explicit)

      File.join(xdg_cache_home, APP_NAME)
    end

    def runtime_root
      explicit = ENV.fetch("DEVBOX_RUNTIME", nil)
      return File.expand_path(explicit) unless blank?(explicit)

      xdg = ENV.fetch("XDG_RUNTIME_DIR", nil)
      return File.join(File.expand_path(xdg), APP_NAME) unless blank?(xdg)

      File.join(Dir.tmpdir, "#{APP_NAME}-#{Process.uid}")
    end

    def xdg_state_home
      xdg = ENV.fetch("XDG_STATE_HOME", nil)
      return File.expand_path(xdg) unless blank?(xdg)

      File.join(Dir.home, ".local", "state")
    end

    def xdg_cache_home
      xdg = ENV.fetch("XDG_CACHE_HOME", nil)
      return File.expand_path(xdg) unless blank?(xdg)

      File.join(Dir.home, ".cache")
    end

    def vm_dir(name)
      File.join(state_root, name)
    end

    def cache_vm_dir(name)
      File.join(cache_root, name)
    end

    def runtime_vm_dir(name)
      File.join(runtime_root, name)
    end

    def blank?(value)
      value.nil? || value.empty?
    end
  end
end

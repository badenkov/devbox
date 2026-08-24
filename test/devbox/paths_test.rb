# frozen_string_literal: true

require "test_helper"

class Devbox::PathsTest < Minitest::Test
  def around
    keys = %w[DEVBOX_STATE DEVBOX_CACHE DEVBOX_RUNTIME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR DEVBOX_ROOT]
    @saved = ENV.to_h.slice(*keys)
    keys.each { |key| ENV.delete(key) }
    super
  ensure
    keys.each { |key| ENV.delete(key) }
    @saved.each { |key, value| ENV[key] = value }
  end

  def test_devbox_state_overrides_everything
    ENV["DEVBOX_STATE"] = "/tmp/devbox-explicit"
    ENV["XDG_STATE_HOME"] = "/tmp/xdg-state"

    assert_equal "/tmp/devbox-explicit", Devbox::Paths.state_root
  end

  def test_xdg_state_home_is_used_when_devbox_state_is_unset
    ENV["XDG_STATE_HOME"] = "/tmp/xdg-state"

    assert_equal "/tmp/xdg-state/devbox", Devbox::Paths.state_root
  end

  def test_default_is_home_local_state
    assert_equal File.join(Dir.home, ".local", "state", "devbox"), Devbox::Paths.state_root
  end

  def test_vm_dir_is_under_state_root
    ENV["DEVBOX_STATE"] = "/tmp/devbox-explicit"

    assert_equal "/tmp/devbox-explicit/try", Devbox::Paths.vm_dir("try")
  end

  def test_cache_and_runtime_roots_can_be_overridden
    ENV["DEVBOX_CACHE"] = "/tmp/devbox-cache"
    ENV["DEVBOX_RUNTIME"] = "/tmp/devbox-runtime"

    assert_equal "/tmp/devbox-cache/try", Devbox::Paths.cache_vm_dir("try")
    assert_equal "/tmp/devbox-runtime/try", Devbox::Paths.runtime_vm_dir("try")
  end

  def test_guest_module_lives_in_the_repo
    assert Devbox::Paths.guest_module.end_with?("/nix/guest.nix")
    assert_path_exists Devbox::Paths.guest_module
    assert_path_exists Devbox::Paths.eval_info
    assert_path_exists Devbox::Paths.tools_nix
  end

  def test_devbox_root_overrides_repo_layout
    ENV["DEVBOX_ROOT"] = "/tmp/devbox-root"

    assert_equal "/tmp/devbox-root", Devbox::Paths.root
    assert_equal "/tmp/devbox-root/nix/guest.nix", Devbox::Paths.guest_module
  end
end

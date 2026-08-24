# frozen_string_literal: true

require "json"
require "test_helper"

class Devbox::StateTest < Minitest::Test
  def around
    previous = ENV.to_h.slice("DEVBOX_STATE", "DEVBOX_CACHE", "DEVBOX_RUNTIME")
    Dir.mktmpdir("devbox-state-") do |dir|
      @tmpdir = dir
      ENV["DEVBOX_STATE"] = File.join(dir, "state")
      ENV["DEVBOX_CACHE"] = File.join(dir, "cache")
      ENV["DEVBOX_RUNTIME"] = File.join(dir, "runtime")
      super
    end
  ensure
    %w[DEVBOX_STATE DEVBOX_CACHE DEVBOX_RUNTIME].each { |key| ENV.delete(key) }
    previous.each { |key, value| ENV[key] = value }
  end

  def test_save_and_load_roundtrip
    state = Devbox::State.new("name" => "try", "status" => "running", "pid" => Process.pid,
                              "forward_pid" => Process.pid,
                              "slot" => 0, "network_prefix" => 30, "memory_mb" => 2048,
                              "kernel" => "/nix/store/kernel")
    state.save

    loaded = Devbox::State.load("try")

    assert_equal "try", loaded.name
    assert_equal "running", loaded.status
    assert_equal "10.201.0.2", loaded["ip"]
    assert_equal 2048, loaded["memory_mb"]
    assert_equal File.join(ENV.fetch("DEVBOX_STATE"), "try", "persist.qcow2"), loaded.disk
    assert_path_exists File.join(loaded.dir, "state.json")
    assert_path_exists Devbox::State.runtime_path_for("try")
    durable = JSON.parse(File.read(File.join(loaded.dir, "state.json")))
    runtime = JSON.parse(File.read(Devbox::State.runtime_path_for("try")))
    assert_equal 2048, durable["memory_mb"]
    refute durable.key?("status")
    assert_equal "running", runtime["status"]
    assert_equal Process.pid, runtime["forward_pid"]
    refute runtime.key?("memory_mb")
    build = JSON.parse(File.read(Devbox::State.build_path_for("try")))
    assert_equal "/nix/store/kernel", build["kernel"]
  end

  def test_list_and_resolve_name
    assert_empty Devbox::State.list
    error = assert_raises(Devbox::Error) { Devbox::State.resolve_name(nil) }
    assert_match(/no VMs/, error.message)

    Devbox::State.new("name" => "alpha", "status" => "created").save
    assert_equal "alpha", Devbox::State.resolve_name(nil)

    Devbox::State.new("name" => "beta", "status" => "created").save
    error = assert_raises(Devbox::Error) { Devbox::State.resolve_name(nil) }
    assert_match(/multiple VMs/, error.message)
    assert_equal "beta", Devbox::State.resolve_name("beta")
  end

  def test_load_missing_vm
    error = assert_raises(Devbox::Error) { Devbox::State.load("missing") }
    assert_match(/no VM named "missing"/, error.message)
  end

  def test_load_migrates_legacy_layout
    dir = File.join(ENV.fetch("DEVBOX_STATE"), "legacy")
    FileUtils.mkdir_p(File.join(dir, "nix", "store"))
    FileUtils.mkdir_p(File.join(dir, "ssh"))
    File.write(File.join(dir, "cloud-hypervisor.log"), "old log\n")
    legacy_vm = {
      "name" => "legacy",
      "config" => "/configs/legacy.nix",
      "memory_mb" => 1024,
      "slot" => 7,
      "kernel" => "/nix/store/kernel",
      "ch" => File.join(dir, "cloud-hypervisor", "bin", "cloud-hypervisor")
    }
    legacy_runtime = {
      "status" => "running", "pid" => 999_999_999, "virtiofsd_pid" => 999_999_998
    }
    File.write(File.join(dir, "vm.json"), JSON.generate(legacy_vm))
    File.write(File.join(dir, "state.json"), JSON.generate(legacy_runtime))

    state = Devbox::State.load("legacy")

    assert_equal 3, state["format_version"]
    assert_equal 24, state["network_prefix"]
    assert_equal "10.201.7.2", state["ip"]
    assert_equal "stopped", state.status
    assert_equal "/configs/legacy.nix", state["source_config"]
    assert_equal "/nix/store/kernel", state["kernel"]
    assert_path_exists File.join(state.store_root, "nix", "store")
    assert_path_exists state.hypervisor_log
    refute_path_exists File.join(dir, "vm.json")
    durable = JSON.parse(File.read(File.join(dir, "state.json")))
    refute durable.key?("status")
    refute durable.key?("kernel")
  end

  def test_load_migrates_v2_identity_to_slot_without_changing_addresses
    dir = File.join(ENV.fetch("DEVBOX_STATE"), "old")
    FileUtils.mkdir_p(dir)
    old_state = {
      "format_version" => 2,
      "name" => "old",
      "slot" => 12,
      "tap" => "devbox12",
      "ip" => "10.201.12.2",
      "host_ip" => "10.201.12.1",
      "mac" => "02:db:00:00:0c:02"
    }
    File.write(File.join(dir, "state.json"), JSON.generate(old_state))

    state = Devbox::State.load("old")

    assert_equal 3, state["format_version"]
    assert_equal 24, state["network_prefix"]
    assert_equal "devbox12", state["tap"]
    assert_equal "10.201.12.2", state["ip"]
    assert_equal "10.201.12.1", state["host_ip"]
    assert_equal "02:db:00:00:0c:02", state["mac"]
    durable = JSON.parse(File.read(File.join(dir, "state.json")))
    Devbox::State::IDENTITY_KEYS.each { |key| refute durable.key?(key) }
  end

  def test_network_identity_cannot_be_overridden
    state = Devbox::State.new("name" => "try", "slot" => 1)

    error = assert_raises(Devbox::Error) { state["ip"] = "192.0.2.1" }

    assert_match(/derived from slot/, error.message)
    assert_equal "10.201.1.2", state["ip"]
  end
end

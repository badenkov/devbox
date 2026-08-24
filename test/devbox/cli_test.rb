# frozen_string_literal: true

require "test_helper"
require "open3"

class Devbox::CLITest < Minitest::Test
  def invoke(*args)
    capture_io { Devbox::CLI.start(args) }
  end

  def test_version
    out, _err = invoke("version")

    assert_includes out, Devbox::VERSION
  end

  def test_loads_when_thor_has_no_tree_command
    script = <<~RUBY
      require "thor"
      Thor.send(:undef_method, :tree) if Thor.method_defined?(:tree)
      require "devbox"
    RUBY
    lib = File.expand_path("../../lib", __dir__)

    _out, err, status = Open3.capture3(RbConfig.ruby, "-I#{lib}", "-e", script)

    assert_predicate status, :success?, err
  end

  def test_create_and_apply_take_config
    Devbox::Machine.stub(:create, ->(*args) { puts "create #{args.join(" ")}" }) do
      out, _err = invoke("create", "./config.nix")
      assert_includes out, "create ./config.nix"

      out, _err = invoke("create", "./config.nix", "try")
      assert_includes out, "create ./config.nix try"
    end

    Devbox::Machine.stub(:apply, ->(*args) { puts "apply #{args.join(" ")}" }) do
      out, _err = invoke("apply", "./config.nix")
      assert_includes out, "apply ./config.nix"

      out, _err = invoke("apply", "./config.nix", "try")
      assert_includes out, "apply ./config.nix try"
    end
  end

  def test_start_and_stop_take_optional_name
    %w[start stop].each do |command|
      Devbox::Machine.stub(command.to_sym, ->(name = nil) { puts "#{command} #{name.inspect}" }) do
        out, _err = invoke(command)
        assert_includes out, "#{command} nil"

        out, _err = invoke(command, "try")
        assert_includes out, "#{command} \"try\""
      end
    end
  end

  def test_help_lists_lifecycle_commands
    out, _err = invoke("help")

    %w[create start stop apply ls status shell exec forward console logs ssh rm].each do |command|
      assert_includes out, command
    end
    assert_includes out, "devbox create"
    assert_match(/create CONFIG/, out)
    assert_match(/apply CONFIG/, out)
    assert_match(/create CONFIG \[NAME\]/, out)
    refute_match(/start \[?CONFIG/, out)
    refute_match(/stop \[?CONFIG/, out)
    refute_includes out, "devbox sleep"
    refute_includes out, "tree"
    refute_includes out, "show NAME"
    assert_match(/status NAME/, out)
    assert_match(/ssh \[NAME\]/, out)
    assert_match(/shell \[NAME\]/, out)
    assert_match(/exec NAME -- COMMAND/, out)
    assert_match(/forward NAME HOST\[:GUEST\]/, out)
    assert_match(/console \[NAME\]/, out)
    assert_match(/logs \[NAME\]/, out)
    assert_match(/rm NAME/, out)
  end

  def test_shell_exec_console_and_logs_delegate
    Devbox::Machine.stub(:shell, ->(name = nil) { puts "shell #{name}" }) do
      out, _err = invoke("shell", "try")
      assert_includes out, "shell try"
    end

    called = nil
    handler = lambda do |name, command, interactive:, tty:|
      called = [name, command, interactive, tty]
    end
    Devbox::Machine.stub(:exec, handler) do
      invoke("exec", "-it", "try", "--", "bash", "-l")
    end
    assert_equal ["try", ["bash", "-l"], true, true], called

    Devbox::Machine.stub(:console, ->(name = nil) { puts "console #{name}" }) do
      out, _err = invoke("console", "try")
      assert_includes out, "console try"
    end

    called = nil
    Devbox::Machine.stub(:logs, ->(name = nil, follow:) { called = [name, follow] }) do
      invoke("logs", "-f", "try")
    end
    assert_equal ["try", true], called
  end

  def test_forward_delegates_mapping_without_reparsing
    called = nil
    Devbox::Machine.stub(:forward, ->(name, mapping) { called = [name, mapping] }) do
      invoke("forward", "try", "8080:3000")
    end

    assert_equal ["try", "8080:3000"], called
  end

  def test_ls_and_status_delegate
    Devbox::Machine.stub(:ls, -> { puts "listed" }) do
      out, _err = invoke("ls")
      assert_includes out, "listed"
    end

    Devbox::Machine.stub(:status, ->(name) { puts "status #{name}" }) do
      out, _err = invoke("status", "try")
      assert_includes out, "status try"
    end

    Devbox::Machine.stub(:ssh, ->(name, cmd = []) { puts "ssh #{name} #{cmd.join(" ")}" }) do
      out, _err = invoke("ssh", "try")
      assert_includes out, "ssh try"
    end

    Devbox::Machine.stub(:rm, ->(name) { puts "rm #{name}" }) do
      out, _err = invoke("rm", "try")
      assert_includes out, "rm try"
    end
  end
end

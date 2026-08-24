# frozen_string_literal: true

require "test_helper"

class Devbox::RunnerTest < Minitest::Test
  def test_capture_without_chdir
    out = Devbox::Runner.new.capture!("true")

    assert_equal "", out
  end

  def test_capture_with_chdir
    Dir.mktmpdir("devbox-runner-") do |dir|
      File.write(File.join(dir, "marker"), "ok\n")
      out = Devbox::Runner.new.capture!("cat", "marker", chdir: dir)

      assert_equal "ok\n", out
    end
  end

  def test_capture_passes_exact_stdin_data
    out = Devbox::Runner.new.capture!("ruby", "-e", "STDOUT.write(STDIN.read)", stdin_data: "policy json")

    assert_equal "policy json", out
  end

  def test_privileged_passes_stdin_to_direct_command
    out = Devbox::Runner.new.privileged!(
      "ruby", "-e", "STDOUT.write(STDIN.read)", stdin_data: "network policy"
    )

    assert_equal "network policy", out
  end
end

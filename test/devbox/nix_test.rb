# frozen_string_literal: true

require "test_helper"

class Devbox::NixTest < Minitest::Test
  class NoCommands
    def capture!(*cmd, **)
      raise "unexpected command: #{cmd.join(" ")}"
    end
  end

  def test_prepare_project_copies_source_and_preserves_project_pin
    Dir.mktmpdir("devbox-nix-") do |dir|
      source = File.join(dir, "source")
      project = File.join(dir, "project")
      FileUtils.mkdir_p(File.join(source, "npins"))
      File.write(File.join(source, "config.nix"), "{ imports = [ ./extra.nix ]; }\n")
      File.write(File.join(source, "extra.nix"), "{}\n")
      File.write(File.join(source, "npins", "default.nix"), "{}\n")
      File.write(File.join(source, "npins", "sources.json"), "source pin\n")
      nix = Devbox::Nix.new(runner: NoCommands.new)

      nix.prepare_project(File.join(source, "config.nix"), project)

      assert_path_exists File.join(project, "user", "config.nix")
      assert_path_exists File.join(project, "user", "extra.nix")
      assert_path_exists File.join(project, "devbox", "guest.nix")
      assert_equal "source pin\n", File.read(File.join(project, "npins", "sources.json"))
      refute_path_exists File.join(project, "user", "npins")

      File.write(File.join(source, "npins", "sources.json"), "new source pin\n")
      nix.prepare_project(File.join(source, "config.nix"), project, preserve_npins: true)

      assert_equal "source pin\n", File.read(File.join(project, "npins", "sources.json"))
      assert_equal "new source pin\n", File.read(File.join(source, "npins", "sources.json"))
    end
  end
end

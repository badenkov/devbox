# frozen_string_literal: true

require_relative "lib/devbox/version"

Gem::Specification.new do |spec|
  spec.name = "devbox"
  spec.version = Devbox::VERSION
  spec.authors = ["Alexey Badenkov"]
  spec.email = ["alexey.badenkov@gmail.com"]

  spec.summary = "NixOS VMs on Cloud Hypervisor"
  spec.homepage = "https://github.com/badenkov"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["rubygems_mfa_required"] = "true"

  gemspec = File.basename(__FILE__)
  spec.files = if File.directory?(File.join(__dir__, ".git"))
                 IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
                   ls.readlines("\x0", chomp: true).reject do |f|
                     (f == gemspec) ||
                       f.start_with?(*%w[bin/ test/ spec/ features/ .git .github Gemfile])
                   end
                 end
               else
                 Dir.chdir(__dir__) { Dir["lib/**/*.rb"] + Dir["exe/*"] + Dir["nix/**/*"] }
               end
  spec.bindir = "exe"
  spec.executables = %w[devbox]
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.4"
end

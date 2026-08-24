# CLI entry: evaluate a VM NixOS config and emit config.devbox plus boot paths as JSON.
{
  system,
  project,
}: let
  toPath = p: /. + p;
  projectPath = toPath project;
  sources = import (projectPath + "/npins");
  lib = import "${sources.nixpkgs}/lib";
  eval = import "${sources.nixpkgs}/nixos/lib/eval-config.nix" {
    inherit system;
    modules = [projectPath];
  };
  d = eval.config.devbox;
  toplevel = eval.config.system.build.toplevel;
in {
  inherit (d) name memoryMB vcpus diskSizeGB user ip gateway prefixLength forwardPorts;
  network = {
    inherit (d.network) mode allowedCIDRs allowedTCPPorts allowedUDPPorts;
    allowedDomains = map (domain: lib.removePrefix "*." domain) d.network.allowedDomains;
  };
  sshKey =
    if d.sshKey == null
    then null
    else builtins.toString d.sshKey;
  toplevel = "${toplevel}";
  kernel = "${eval.config.system.build.kernel}/${eval.config.system.boot.loader.kernelFile}";
  initrd = "${eval.config.system.build.initialRamdisk}/${eval.config.system.boot.loader.initrdFile}";
  kernelParams = eval.config.boot.kernelParams;
  nixPackage = "${eval.config.nix.package}";
}

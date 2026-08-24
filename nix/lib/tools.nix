# Host tools for a VM's nixpkgs pin.
{
  nixpkgs,
  system,
}: let
  pkgs = import nixpkgs {
    inherit system;
    config = {};
    overlays = [];
  };
in {
  cloud-hypervisor = pkgs.cloud-hypervisor;
  virtiofsd = pkgs.virtiofsd;
}

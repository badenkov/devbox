{
  nixpkgs,
  system,
  toplevel,
}: let
  pkgs = import nixpkgs {
    inherit system;
    config = {};
    overlays = [];
  };
in
  pkgs.closureInfo {
    rootPaths = [toplevel];
  }

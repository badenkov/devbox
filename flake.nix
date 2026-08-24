{
  description = "devbox — NixOS VMs on Cloud Hypervisor";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
  };

  outputs = {
    self,
    nixpkgs,
  }: let
    supportedSystems = ["x86_64-linux" "aarch64-linux"];
    forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
  in {
    packages = forAllSystems (system:
      import ./nix/packages.nix {
        pkgs = nixpkgs.legacyPackages.${system};
        root = ./.;
      });

    checks = forAllSystems (system: {
      host-module = import ./nix/host/test.nix {
        inherit system;
        nixpkgs = nixpkgs;
        module = self.nixosModules.devbox;
      };
    });

    nixosModules = {
      default = self.nixosModules.devbox;
      devbox = ./nix/host/devbox.nix;
    };

    devShells = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      localPackages = self.packages.${system};
      ruby = pkgs.ruby_3_4;
      bundler = pkgs.bundler.override {inherit ruby;};
    in {
      default = pkgs.mkShell {
        packages = [
          ruby
          bundler
          pkgs.bundix
          pkgs.libyaml
          pkgs.npins
          pkgs.nix
          pkgs.git
          pkgs.cloud-hypervisor
          pkgs.virtiofsd
          pkgs.iproute2
          pkgs.nftables
          pkgs.dnsmasq
          pkgs.bind.dnsutils
          pkgs.qemu-utils
          pkgs.e2fsprogs
          pkgs.openssh
          pkgs.socat
          pkgs.curl
          localPackages.devbox-net
        ];

        shellHook = ''
          export GEM_HOME="$PWD/.devstate/bundle"
          export BUNDLE_PATH="$GEM_HOME"
          export RUBOCOP_CACHE_ROOT="$PWD/.devstate/rubocop_cache"
          export PATH="$PWD/bin:$BUNDLE_PATH/bin:$PATH"
          export DEVBOX_STATE="$PWD/tmp/state"
          export DEVBOX_CACHE="$PWD/tmp/cache"
          export DEVBOX_RUNTIME="$PWD/tmp/runtime"
          export DEVBOX_NET_HELPER="${localPackages.devbox-net}/bin/devbox-net"
          mkdir -p "$DEVBOX_STATE" "$DEVBOX_CACHE" "$DEVBOX_RUNTIME"
        '';
      };
    });
  };
}

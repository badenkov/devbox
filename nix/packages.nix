{
  pkgs,
  root ? ../.,
}: let
  ruby = pkgs.ruby_3_4.withPackages (ps: [ps.thor]);
  devboxNet = pkgs.replaceVarsWith {
    name = "devbox-net";
    src = root + "/exe/devbox-net";
    dir = "bin";
    isExecutable = true;
    replacements = {
      ruby = pkgs.ruby_3_4;
      lib = "${root}/lib";
      ip = "${pkgs.iproute2}/bin/ip";
      nft = "${pkgs.nftables}/bin/nft";
      dnsmasq = "${pkgs.dnsmasq}/bin/dnsmasq";
    };
  };
  devbox = pkgs.writeShellApplication {
    name = "devbox";
    runtimeInputs = [
      ruby
      pkgs.npins
      pkgs.nix
      pkgs.git
      pkgs.cloud-hypervisor
      pkgs.virtiofsd
      pkgs.iproute2
      pkgs.qemu-utils
      pkgs.e2fsprogs
      pkgs.openssh
      pkgs.socat
      pkgs.curl
    ];
    text = ''
      export DEVBOX_ROOT="${root}"
      export DEVBOX_NET_HELPER="${devboxNet}/bin/devbox-net"
      export RUBYLIB="${root}/lib''${RUBYLIB:+:$RUBYLIB}"
      exec ruby "${root}/exe/devbox" "$@"
    '';
  };
in {
  default = devbox;
  inherit devbox;
  devbox-net = devboxNet;
}

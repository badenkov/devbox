{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.devbox;
  localPackages = import ../packages.nix {inherit pkgs;};
  tapGroup = 201;
  allowMark = "0x0000db01";
  privateAllowMark = "0x0000db02";
  hostAllowMark = "0x0000db03";
  privateDestinations = [
    "0.0.0.0/8"
    "10.0.0.0/8"
    "100.64.0.0/10"
    "127.0.0.0/8"
    "169.254.0.0/16"
    "172.16.0.0/12"
    "192.0.0.0/24"
    "192.0.2.0/24"
    "192.168.0.0/16"
    "198.18.0.0/15"
    "198.51.100.0/24"
    "203.0.113.0/24"
    "224.0.0.0/4"
    "240.0.0.0/4"
  ];
  privateSet = lib.concatStringsSep ", " privateDestinations;
  dockerForwardRules = lib.optionalString (config.virtualisation.docker.enable && cfg.dockerCompatibility) ''
    iifname "docker0" accept comment "devbox: leave Docker bridge policy to Docker"
    iifname "br-*" accept comment "devbox: leave Docker user bridge policy to Docker"
  '';
in {
  options.programs.devbox = {
    enable = lib.mkEnableOption "local NixOS machines managed by devbox";

    package = lib.mkOption {
      type = lib.types.package;
      default = localPackages.devbox;
      defaultText = lib.literalExpression "packages.devbox";
      description = "The devbox CLI package installed on the host.";
    };

    netHelperPackage = lib.mkOption {
      type = lib.types.package;
      default = localPackages.devbox-net;
      defaultText = lib.literalExpression "packages.devbox-net";
      description = "The immutable privileged devbox-net helper package.";
    };

    allowedUsers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["alice"];
      description = "Users allowed to run the exact devbox-net store path through sudo without a password.";
    };

    dockerCompatibility = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When Docker is enabled, allow forwarding originating on docker0 and br-* through the NixOS
        nftables firewall. Docker's own iptables policy remains authoritative for that traffic.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.nftables.enable;
        message = "programs.devbox requires networking.nftables.enable";
      }
      {
        assertion = config.networking.firewall.enable;
        message = "programs.devbox requires the NixOS firewall";
      }
      {
        assertion = config.networking.firewall.backend == "nftables";
        message = "programs.devbox requires networking.firewall.backend = \"nftables\"";
      }
      {
        assertion = config.networking.firewall.filterForward;
        message = "programs.devbox requires networking.firewall.filterForward";
      }
      {
        assertion = cfg.allowedUsers == [] || config.security.sudo.enable;
        message = "programs.devbox.allowedUsers requires security.sudo.enable";
      }
    ];

    warnings = lib.optional (config.virtualisation.docker.enable && !cfg.dockerCompatibility) ''
      Docker is enabled while programs.devbox.dockerCompatibility is false. The NixOS nftables
      forward policy may block Docker container forwarding.
    '';

    environment.systemPackages = [
      cfg.package
      cfg.netHelperPackage
      pkgs.dnsmasq
      pkgs.nftables
    ];

    users.groups.devbox-dns = {};
    users.users.devbox-dns = {
      isSystemUser = true;
      group = "devbox-dns";
      description = "Unprivileged per-VM devbox DNS proxy";
    };

    boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkDefault 1;

    networking.nftables.enable = lib.mkDefault true;
    networking.firewall = {
      enable = lib.mkDefault true;
      filterForward = lib.mkDefault true;

      extraInputRules = ''
        iifgroup ${toString tapGroup} ip daddr 10.201.0.0/16 udp dport 53 accept comment "devbox DNS"
        iifgroup ${toString tapGroup} ip daddr 10.201.0.0/16 tcp dport 53 accept comment "devbox DNS"
        iifgroup ${toString tapGroup} ip protocol icmp icmp type { destination-unreachable, time-exceeded, parameter-problem, echo-request } accept comment "devbox ICMP"
        iifgroup ${toString tapGroup} drop comment "devbox deny guest to host"
      '';

      extraForwardRules = ''
        iifgroup ${toString tapGroup} meta mark { ${allowMark}, ${privateAllowMark} } accept comment "devbox allowed guest forwarding"
        ${dockerForwardRules}
      '';
    };

    networking.nftables.tables.devbox = {
      family = "inet";
      content = ''
        define tap_group = ${toString tapGroup}
        define allow_mark = ${allowMark}
        define private_allow_mark = ${privateAllowMark}
        define host_allow_mark = ${hostAllowMark}

        chain input_dispatch {
        }

        chain forward_dispatch {
        }

        chain input {
          type filter hook input priority filter - 10; policy accept;
          iifgroup $tap_group meta nfproto ipv6 drop comment "devbox deny guest IPv6 to host"
          iifgroup $tap_group ct direction reply ct state { established, related } accept
          iifgroup $tap_group meta mark set 0
          iifgroup $tap_group jump input_dispatch
          iifgroup $tap_group meta mark $host_allow_mark accept
          iifgroup $tap_group drop comment "devbox no active host policy"
        }

        chain forward {
          type filter hook forward priority filter - 10; policy accept;
          iifgroup $tap_group oifgroup $tap_group drop comment "devbox deny VM to VM"
          iifgroup $tap_group meta nfproto ipv6 drop comment "devbox deny forwarded guest IPv6"
          iifgroup $tap_group meta mark set 0
          iifgroup $tap_group jump forward_dispatch
          iifgroup $tap_group meta mark $private_allow_mark accept
          iifgroup $tap_group ip daddr { ${privateSet} } drop comment "devbox deny private destinations by default"
          iifgroup $tap_group meta mark $allow_mark accept
          iifgroup $tap_group drop comment "devbox no active forwarding policy"
        }

        chain postrouting {
          type nat hook postrouting priority srcnat;
          ip saddr 10.201.0.0/16 meta mark { $allow_mark, $private_allow_mark } masquerade comment "devbox allowed IPv4 NAT"
        }
      '';
    };

    security.sudo.extraRules = lib.optional (cfg.allowedUsers != []) {
      users = cfg.allowedUsers;
      commands = [
        {
          command = "${cfg.netHelperPackage}/bin/devbox-net";
          options = ["NOPASSWD" "NOSETENV"];
        }
      ];
    };

    systemd.tmpfiles.rules = [
      "d /run/devbox-net 0700 root root -"
    ];
  };
}

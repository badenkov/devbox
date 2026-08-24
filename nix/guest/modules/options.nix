{lib, ...}: let
  port = lib.types.ints.between 1 65535;
  domain = lib.types.addCheck lib.types.str (value: let
    normalized = lib.removePrefix "*." value;
    labels = lib.splitString "." normalized;
    validLabel = label:
      builtins.match "[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?" label != null;
  in
    labels != []
    && lib.all validLabel labels);
  ipv4CIDR = lib.types.addCheck lib.types.str (value: let
    cidr = lib.splitString "/" value;
    octets = lib.splitString "." (lib.head cidr);
    decimal = part: builtins.match "[0-9]+" part != null;
  in
    builtins.length cidr == 2
    && builtins.length octets == 4
    && lib.all (part: decimal part && lib.toInt part <= 255) octets
    && decimal (lib.last cidr)
    && lib.toInt (lib.last cidr) <= 32);
in {
  options.devbox = {
    name = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[a-z][a-z0-9-]{0,31}");
      default = null;
      description = "VM name. Runtime state is stored in DEVBOX_STATE/<name>. Can be set on the CLI instead.";
    };

    memoryMB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2048;
      description = "Guest RAM in MiB.";
    };

    vcpus = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Number of virtual CPUs.";
    };

    diskSizeGB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 16;
      description = "Persistent workspace size in GiB (/home, /var). Not the Nix store.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "dev";
      description = "Unprivileged guest user with sudo and SSH.";
    };

    sshKey = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Public key installed into the guest user's authorized_keys.";
    };

    ip = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Guest IPv4 address on the TAP network. Filled in by the CLI.";
    };

    gateway = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host TAP IPv4 address used as the guest default gateway.";
    };

    prefixLength = lib.mkOption {
      type = lib.types.ints.between 0 32;
      default = 30;
      internal = true;
      description = "Guest TAP network prefix. Filled in by the CLI.";
    };

    network = {
      mode = lib.mkOption {
        type = lib.types.enum ["off" "allowlist" "open"];
        default = "allowlist";
        description = "Host-enforced outbound network policy.";
      };

      allowedDomains = lib.mkOption {
        type = lib.types.listOf domain;
        default = [];
        description = "DNS suffixes whose resolved IPv4 addresses may be reached.";
      };

      allowedCIDRs = lib.mkOption {
        type = lib.types.listOf ipv4CIDR;
        default = [];
        description = "Explicit IPv4 destination networks allowed by host policy.";
      };

      allowedTCPPorts = lib.mkOption {
        type = lib.types.listOf port;
        default = [80 443];
        description = "Allowed outbound TCP destination ports.";
      };

      allowedUDPPorts = lib.mkOption {
        type = lib.types.listOf port;
        default = [];
        description = "Allowed outbound UDP destination ports.";
      };
    };

    forwardPorts = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          bind = lib.mkOption {
            type = lib.types.enum ["127.0.0.1"];
            default = "127.0.0.1";
            description = "Host loopback address on which the SSH forward listens.";
          };
          hostPort = lib.mkOption {
            type = port;
            description = "Host TCP port.";
          };
          guestPort = lib.mkOption {
            type = port;
            description = "Guest loopback TCP port.";
          };
        };
      });
      default = [];
      description = "Declarative localhost TCP forwards implemented over SSH.";
    };
  };
}

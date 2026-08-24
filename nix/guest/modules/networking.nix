{
  config,
  lib,
  ...
}: let
  cfg = config.devbox;
in {
  networking.hostName = lib.mkIf (cfg.name != null) cfg.name;
  networking.useDHCP = false;
  networking.useNetworkd = true;
  networking.usePredictableInterfaceNames = false;
  networking.firewall.enable = lib.mkDefault false;

  systemd.network.enable = true;
  systemd.network.networks."10-virtio" = lib.mkIf (cfg.ip != null) {
    matchConfig.Name = "eth0";
    address = ["${cfg.ip}/${toString cfg.prefixLength}"];
    gateway = lib.mkIf (cfg.gateway != null) [cfg.gateway];
    dns = lib.optional (cfg.gateway != null) cfg.gateway;
    networkConfig = {
      DHCP = "no";
      LinkLocalAddressing = "no";
      IPv6AcceptRA = false;
    };
  };
}

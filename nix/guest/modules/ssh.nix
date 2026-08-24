{
  config,
  lib,
  ...
}: let
  cfg = config.devbox;
in {
  services.openssh.enable = true;
  services.openssh.hostKeys = [
    {
      path = "/var/lib/sshd/ssh_host_ed25519_key";
      type = "ed25519";
    }
  ];
  services.openssh.settings = {
    PasswordAuthentication = false;
    KbdInteractiveAuthentication = false;
    PermitRootLogin = "no";
  };

  users.users.${cfg.user} = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    openssh.authorizedKeys.keyFiles = lib.mkIf (cfg.sshKey != null) [cfg.sshKey];
  };
  security.sudo.wheelNeedsPassword = false;
}

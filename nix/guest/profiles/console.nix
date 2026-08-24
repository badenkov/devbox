{
  config,
  lib,
  ...
}: {
  boot.kernelParams = [
    "console=ttyS0,115200n8"
    "console=hvc0"
  ];
  services.getty.autologinUser = lib.mkDefault config.devbox.user;
}

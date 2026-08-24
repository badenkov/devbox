{
  config,
  lib,
  pkgs,
  ...
}: let
  user = config.devbox.user;
in {
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.external.enable = true;
  boot.loader.external.installHook = "${pkgs.coreutils}/bin/true";
  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtio_mmio"
    "virtiofs"
    "ext4"
  ];
  boot.initrd.kernelModules = [
    "virtio_pci"
    "virtio_blk"
    "virtiofs"
  ];
  boot.growPartition = true;

  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
    options = ["defaults" "mode=755" "size=50%"];
  };

  fileSystems."/nix/store" = {
    device = "nix-store";
    fsType = "virtiofs";
    options = ["ro" "defaults"];
    neededForBoot = true;
  };

  fileSystems."/persist" = {
    device = "/dev/disk/by-label/persist";
    fsType = "ext4";
    autoResize = true;
    neededForBoot = true;
  };

  fileSystems."/home" = {
    device = "/persist/home";
    fsType = "none";
    options = ["bind"];
    depends = ["/persist"];
  };

  fileSystems."/var" = {
    device = "/persist/var";
    fsType = "none";
    options = ["bind"];
    depends = ["/persist"];
    neededForBoot = true;
  };

  boot.initrd.systemd.services.devbox-persist-dirs = {
    description = "Create persist bind-mount sources";
    wantedBy = ["initrd.target"];
    after = ["sysroot-persist.mount"];
    before = ["sysroot-home.mount" "sysroot-var.mount" "initrd-fs.target"];
    unitConfig.DefaultDependencies = false;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p /sysroot/persist/home /sysroot/persist/var
    '';
  };

  systemd.tmpfiles.rules = [
    "d /persist/home 0755 root root -"
    "d /persist/home/${user} 0700 ${user} users -"
    "d /persist/var 0755 root root -"
  ];

  system.stateVersion = lib.mkDefault "26.11";

  # Activation is driven from the host; the guest store is read-only.
  systemd.services.nix-daemon.enable = false;
  systemd.sockets.nix-daemon.enable = false;
  system.switch.enable = true;
}

{
  imports = [
    ./guest/modules/options.nix
    ./guest/modules/boot.nix
    ./guest/modules/networking.nix
    ./guest/modules/ssh.nix
    ./guest/profiles/qemu.nix
    ./guest/profiles/console.nix
  ];
}

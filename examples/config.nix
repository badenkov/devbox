{pkgs, ...}: {
  devbox.name = "example";
  devbox.memoryMB = 2048;
  devbox.vcpus = 2;
  devbox.diskSizeGB = 8;

  devbox.network = {
    mode = "allowlist";
    allowedDomains = ["github.com" "*.githubusercontent.com"];
    allowedCIDRs = [];
    allowedTCPPorts = [80 443];
    allowedUDPPorts = [];
  };

  devbox.forwardPorts = [
    {
      bind = "127.0.0.1";
      hostPort = 3000;
      guestPort = 3000;
    }
  ];

  environment.systemPackages = [pkgs.mc pkgs.python3];
}

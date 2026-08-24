{
  nixpkgs,
  system,
  module,
}: let
  pkgs = import nixpkgs {inherit system;};
  evaluated = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      module
      {
        programs.devbox = {
          enable = true;
          allowedUsers = ["alice"];
        };
        virtualisation.docker.enable = true;
        system.stateVersion = "26.11";
      }
    ];
  };
  invalidFirewall = nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      module
      {
        programs.devbox.enable = true;
        networking.firewall.enable = false;
        system.stateVersion = "26.11";
      }
    ];
  };
  cfg = evaluated.config;
  table = pkgs.writeText "devbox-table.nft" cfg.networking.nftables.tables.devbox.content;
  inputRules = pkgs.writeText "devbox-input.nft" cfg.networking.firewall.extraInputRules;
  forwardRules = pkgs.writeText "devbox-forward.nft" cfg.networking.firewall.extraForwardRules;
  fullRuleset = builtins.elemAt cfg.systemd.services.nftables.serviceConfig.ExecStart 1;
  sudoRule = nixpkgs.lib.findFirst (rule: rule.users or [] == ["alice"]) null cfg.security.sudo.extraRules;
  sudoCommand = builtins.head sudoRule.commands;
  disabledFirewallAssertion =
    nixpkgs.lib.findFirst (
      assertion: nixpkgs.lib.hasInfix "requires the NixOS firewall" assertion.message
    )
    null
    invalidFirewall.config.assertions;
in
  assert cfg.networking.nftables.enable;
  assert cfg.networking.firewall.enable;
  assert cfg.networking.firewall.backend == "nftables";
  assert cfg.networking.firewall.filterForward;
  assert cfg.boot.kernel.sysctl."net.ipv4.ip_forward" == 1;
  assert cfg.users.users.devbox-dns.isSystemUser;
  assert cfg.users.users.devbox-dns.group == "devbox-dns";
  assert sudoRule != null;
  assert sudoCommand.options == ["NOPASSWD" "NOSETENV"];
  assert disabledFirewallAssertion != null && !disabledFirewallAssertion.assertion;
    pkgs.runCommand "devbox-host-module-test" {
      nativeBuildInputs = [pkgs.nftables];
    } ''
      grep -F 'iifgroup $tap_group oifgroup $tap_group drop' ${table}
      grep -F 'meta mark set 0' ${table}
      grep -F 'meta mark $private_allow_mark accept' ${table}
      grep -F 'meta mark { $allow_mark, $private_allow_mark } masquerade' ${table}
      grep -F 'drop comment "devbox no active forwarding policy"' ${table}
      grep -F 'iifgroup 201 drop' ${inputRules}
      grep -F 'meta mark { 0x0000db01, 0x0000db02 } accept' ${forwardRules}
      grep -F 'iifname "docker0" accept' ${forwardRules}

      {
        echo 'table inet devbox {'
        cat ${table}
        echo '}'
      } > ruleset.nft
      LD_PRELOAD="${pkgs.buildPackages.lklWithFirewall.lib}/lib/liblkl-hijack.so" \
        nft --check --file ruleset.nft

      test -x ${fullRuleset}
      test '${sudoCommand.command}' = '${cfg.programs.devbox.netHelperPackage}/bin/devbox-net'
      touch $out
    ''

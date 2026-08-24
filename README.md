# devbox

Local NixOS machines running on Cloud Hypervisor. The configuration is a regular NixOS module, not a flake.

The guest `/nix/store` is an isolated, recoverable store in the VM cache (read-only via virtiofs). Persistence is a small disk for `/home` and `/var`. The kernel is loaded from the host.

## Configuration

```nix
{ pkgs, ... }: {
  devbox.name = "try";
  devbox.memoryMB = 8192;
  devbox.vcpus = 4;
  devbox.diskSizeGB = 32;  # persistence, not the store
  # devbox.sshKey = ./id_ed25519.pub;

  # Outbound networking is enforced on the host, not inside the VM.
  devbox.network = {
    mode = "allowlist";  # off | allowlist | open
    allowedDomains = [ "github.com" "*.githubusercontent.com" ];
    allowedCIDRs = [ ];
    allowedTCPPorts = [ 80 443 ];
    allowedUDPPorts = [ ];
  };

  # 127.0.0.1:3000 on the host -> 127.0.0.1:3000 in the guest via SSH.
  devbox.forwardPorts = [{
    bind = "127.0.0.1";
    hostPort = 3000;
    guestPort = 3000;
  }];

  environment.systemPackages = [ pkgs.git pkgs.vim ];
}
```

`create` does not modify the source configuration directory. It copies the config tree into a self-contained Nix project inside the VM state, adds the devbox templates there, and creates its own `npins`. Relative `imports = [ ./other.nix ]` continue to work because the directory structure is preserved. `.git`, `.direnv`, `npins`, `result*`, and `tmp` are excluded from the copy.

## Commands

| | |
|---|---|
| `devbox create CONFIG [NAME]` | build the toplevel and populate the store and persistence disk |
| `devbox start [NAME]` | start the VM in the background |
| `devbox stop [NAME]` | shut down the VM cleanly |
| `devbox apply CONFIG [NAME]` | transactionally update the system, policy, and forwards |
| `devbox shell [NAME]` | interactive login shell over SSH |
| `devbox exec NAME -- COMMAND...` | execute a command over SSH |
| `devbox forward NAME HOST[:GUEST]` | attached localhost forward to the VM |
| `devbox console [NAME]` | connect to the VM serial console |
| `devbox logs [-f] [NAME]` | show Cloud Hypervisor logs |
| `devbox ls` | list VMs |
| `devbox status NAME` | show status and parameters |
| `devbox ssh [NAME]` | legacy low-level SSH interface |
| `devbox rm NAME` | remove the VM and its state |

The name is taken from `NAME` or `devbox.name`. `start` returns after launching the VM; closing the terminal does not shut it down. TAP, DNS, and host firewall policy are created on `start` and removed on `stop` through a narrowly scoped privileged helper. Changing the kernel after `apply` requires `stop` and `start`.

For a running VM, `apply` prepares a new project in staging, populates the store, then changes the host policy, activates the guest system, and applies the declarative forward diff without restarting the VM. On failure, these layers are rolled back and the durable project/state remain unchanged. The guest Nix DB is not updated: `/nix/store` is mounted read-only, and its contents and metadata are prepared on the host. Added packages become available without a reboot; a new kernel requires `stop`/`start`. For a stopped VM, `apply` only records the new durable specification; the network is materialized on the next `start`.

The usual workflow is similar to Docker:

```sh
devbox start example
devbox shell example
devbox exec example -- systemctl status nginx
devbox stop example
```

`exec` is non-interactive by default and returns the SSH command's exit code. Use the familiar flags for stdin and a pseudo-terminal:

```sh
devbox exec -i example -- sh -c 'cat > /tmp/input'
devbox exec -it example -- bash
devbox exec -it example -- htop
```

Use `console` for boot failures and when SSH is unavailable:

```sh
devbox console example
```

`exit` and `Ctrl-D` terminate only the guest shell; the serial getty immediately starts a new automatically logged-in session. To detach from the console, switch to an English keyboard layout and press `Ctrl-]` (`Ctrl` together with the `]` key). This does not shut down the VM. You can also simply close the terminal—the background VM continues running.

CH service output is written to `cloud-hypervisor.log`; follow it with `devbox logs -f example`. On a new start, the previous log is renamed to `cloud-hypervisor.log.previous`.

If the runtime was lost while the VM process is still alive, `start` reports that the disk is busy. `devbox stop NAME` finds the old processes, terminates them, and cleans up the TAP; the VM can then be started again.

On btrfs, the store is copied using reflinks; otherwise `nix copy` is used.

## Host setup and network policy

On NixOS, enable the host module and specify the users allowed to run the exact `devbox-net` store path:

```nix
{
  inputs.devbox.url = "path:/path/to/devbox";

  outputs = { nixpkgs, devbox, ... }: {
    nixosConfigurations.my-host = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        devbox.nixosModules.devbox
        ({ ... }: {
          programs.devbox = {
            enable = true;
            allowedUsers = [ "alice" ];
          };
        })
      ];
    };
  };
}
```

The module enables IPv4 forwarding, integrates devbox policy with the standard NixOS nftables firewall, and installs the CLI/helper. It requires `networking.firewall.enable = true`, the nftables backend, and `filterForward`. When Docker is enabled, compatibility with `docker0` and `br-*` is enabled by default; it can be disabled with `programs.devbox.dockerCompatibility = false`.

Guest policy modes:

- `off` prohibits external forwarding;
- `allowlist` requires both a destination match against a domain-derived IP or `allowedCIDRs` and an allowed TCP/UDP port; an empty allowlist denies everything;
- `open` allows ordinary outbound IPv4, while VM-to-VM and VM-to-host isolation remains in place.

Direct connections to private, link-local, metadata, and `10.201.0.0/16` destinations are denied by default; explicit exceptions are specified through `allowedCIDRs`. Guest DNS goes only to the per-VM proxy on the host TAP; it uses the host resolver, including VPN split DNS. The domain allowlist operates by IP and is not an HTTP Host/TLS SNI check.

Declarative forwards start in one SSH ControlMaster after SSH is ready. A host-port conflict aborts `start`/`apply`. For a temporary attached forward without changing the configuration:

```sh
devbox forward example 3000       # 3000:3000
devbox forward example 8080:3000  # host 8080 -> guest 3000
```

## Data, cache, and runtime

Durable state is the only part that needs to be backed up:

```text
${DEVBOX_STATE:-${XDG_STATE_HOME:-~/.local/state}/devbox}/example/
├── state.json
├── persist.qcow2
├── ssh/
└── nix/
    ├── default.nix
    ├── machine.nix
    ├── npins/
    ├── devbox/
    └── user/
```

`state.json` contains only the stable VM specification and identity. PIDs, status, sockets, build paths, and the guest store are not written there.

Recoverable cache:

```text
${DEVBOX_CACHE:-${XDG_CACHE_HOME:-~/.cache}/devbox}/example/
├── guest-store/nix/{store,var}/
├── build/{build.json,gcroots}/
└── logs/{cloud-hypervisor.log,virtiofsd.log}
```

The cache can be deleted. The next `start` rebuilds the missing system/store from the saved `state/example/nix` and its pin.

`virtiofsd` exports the store read-only and maps the host-cache owner's UID/GID to `root:root` inside the VM. These mapping parameters are set when `virtiofsd` starts, so changes to this implementation take effect after `devbox stop` and `devbox start`.

Runtime exists only for a running VM:

```text
${DEVBOX_RUNTIME:-$XDG_RUNTIME_DIR/devbox}/example/
├── runtime.json
├── api.sock
├── console.sock
├── virtiofs.sock
└── forward-control.sock
```

If `XDG_RUNTIME_DIR` is unavailable, `/tmp/devbox-$UID` is used. For a consistent qcow backup, first run `devbox stop NAME`, then copy the VM directory from `DEVBOX_STATE`.

All lifecycle commands for a VM must use the same `DEVBOX_STATE`, `DEVBOX_CACHE`, and `DEVBOX_RUNTIME`. Otherwise the CLI may find durable state but fail to see build/runtime data for an already running VM. `nix develop` sets a consistent set of these variables automatically.

## Development

```sh
nix develop   # state/cache/runtime → ./tmp/{state,cache,runtime}
devbox create ./examples/config.nix
devbox start example
devbox shell example

bundle exec rake
nix flake check --no-build
```

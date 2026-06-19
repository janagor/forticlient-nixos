# forticlient-nixos

Run the **official Fortinet FortiClient** VPN client on **NixOS** — including the
combination almost nothing else on Linux handles: **FortiGate IPsec dial-up VPN
with SAML SSO**.

> **Status:** confirmed working end-to-end on **NixOS 24.05 / `x86_64-linux` /
> KDE Plasma + SDDM + Wayland**: EMS registration → IPsec IKEv2 → SAML/Entra-ID
> login → tunnel up. SSL VPN and username/password auth work too. Other desktop
> environments should work but the SAML flow depends on your DE honouring XDG
> autostart (see [Known limitations](#known-limitations)) — reports welcome.

---

## Why this exists

If your company uses a **FortiGate IPsec VPN with SAML single sign-on**, there is
effectively **no open-source Linux client** that can connect:

- `openfortivpn` only speaks **SSL** VPN, not IPsec.
- `strongSwan` / `libreswan` can do FortiGate IPsec, but **not** with SAML —
  FortiClient uses a non-standard SAML-over-IKEv2 mechanism they don't implement.
- The official FortiClient for Linux **does** do IPsec IKEv2 + SAML (7.2.4+), but
  it's a proprietary `.deb` with daemons and an Electron GUI, and **prior attempts
  to package it on NixOS stalled** (hardcoded paths, the SAML browser never
  appearing, etc.).

This module gets the real FortiClient working, declaratively, by running the
**unmodified** binaries under [`nix-ld`](https://github.com/Mic92/nix-ld) and
fixing the handful of NixOS-specific things that quietly break SAML.

## What you get

- FortiClient `forticlient` CLI, `forticlient-gui`, and the system tray
- A **FortiClient** entry in your application menu
- The `fctsched` daemon as a systemd service (spawns `iked`/`vpn` on connect)
- Working **SAML SSO** (the embedded browser actually opens — see *How it works*)
- Optional gnome-keyring credential storage

## Installation

FortiClient is **proprietary**, so you must allow unfree packages:

```nix
nixpkgs.config.allowUnfree = true;
```

### Flakes

```nix
# flake.nix
{
  inputs.forticlient-nixos.url = "github:jplana/forticlient-nixos";

  outputs = { nixpkgs, forticlient-nixos, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        forticlient-nixos.nixosModules.forticlient
        ({ ... }: {
          services.forticlient.enable = true;
          # Auto-unlock the keyring on login — use your display manager:
          services.forticlient.gnomeKeyring.pamServices = [ "login" "sddm" ];
        })
      ];
    };
  };
}
```

### Channels / plain `configuration.nix` (no flakes)

```nix
{ ... }:
{
  imports = [
    (builtins.fetchTarball {
      url = "https://github.com/jplana/forticlient-nixos/archive/main.tar.gz";
      # sha256 = "…"; # pin this for reproducibility (nix-prefetch-url --unpack <url>)
    })
  ];

  services.forticlient.enable = true;
  services.forticlient.gnomeKeyring.pamServices = [ "login" "sddm" ];
}
```

Or vendor it: drop this repo somewhere and `imports = [ ./forticlient-nixos ];`.

Then `sudo nixos-rebuild switch`. The first build downloads ~163 MB and copies
~600 MB into `/opt/forticlient` (takes a minute).

## Usage

1. **Register with EMS** (if your org uses Endpoint Management Server):
   ```bash
   forticlient epctrl register <ems-host-or-ip> [-k <key>]
   ```
   EMS then pushes your VPN profile(s). Check with `forticlient vpn list`.
   (For a standalone tunnel without EMS, configure it in the GUI instead.)
2. **Open FortiClient** from your app menu (or run `forticlient-gui`).
3. **Connect** to your VPN. For SAML, an SSO browser window opens — **log in
   promptly**; there's a 300-second SAML timeout.
4. Verify: `forticlient vpn status`.

The CLI works as a normal (non-root) user — the root daemon does the privileged
work over IPC.

## Configuration options

| Option | Default | Description |
| --- | --- | --- |
| `services.forticlient.enable` | `false` | Enable the module. |
| `services.forticlient.package` | built from the `.deb` | Override to track a different FortiClient release (see below). |
| `services.forticlient.extraLibraries` | `[ ]` | Extra libraries to expose via nix-ld if a future release needs more. |
| `services.forticlient.trayAutostart` | `true` | Autostart the tray on graphical login (required for SAML SSO). |
| `services.forticlient.gnomeKeyring.enable` | `true` | Enable gnome-keyring for credential storage. |
| `services.forticlient.gnomeKeyring.pamServices` | `[ "login" ]` | PAM services to auto-unlock the keyring (add your DM, e.g. `"sddm"`/`"gdm-password"`). |

### Updating the FortiClient version

> **Heads up:** Fortinet's repo **rotates/removes older point releases**, so the
> pinned version here (`7.4.7.1868`) *will* eventually 404. When a fresh build
> fails to download, bump to a current release + its hash.

Find a current build at <https://repo.fortinet.com/repo/forticlient/> and get its
hash with `nix-prefetch-url <deb-url>`, then override the package:

```nix
# Flakes (needs `inputs` in scope — pass specialArgs = { inherit inputs; }):
services.forticlient.package =
  inputs.forticlient-nixos.packages.x86_64-linux.forticlient.override {
    version = "7.4.8.xxxx";
    sha256 = "…";
  };

# Channels / plain configuration.nix (no inputs):
services.forticlient.package =
  pkgs.callPackage ./forticlient-nixos/package.nix {
    version = "7.4.8.xxxx";
    sha256 = "…";
  };
```

## How it works (and the gotchas)

This is the interesting part — the non-obvious things needed to make it work.

- **Unmodified binaries via nix-ld.** FortiClient ships `md5sums` and an
  `exe.manifest`; patching the ELFs (autoPatchelf) risks tripping self-integrity
  checks. Instead we keep them byte-for-byte and let `nix-ld` provide the loader
  and a curated library set.
- **Real FHS paths.** The binaries hardcode `/opt/forticlient`, `/etc/forticlient`
  and `/var/lib/forticlient`. `/opt` must be **writable** (it stores the EMS
  registration marker + cert), so we *copy* the store tree out via
  `systemd.tmpfiles` rather than symlinking it.
- **`restartIfChanged = false`.** On startup `fctsched` does `su - <user>` to
  launch the tray; that session holds the `nixos-rebuild switch` pseudo-terminal
  open and makes the rebuild *hang*. Not restarting the service on rebuilds avoids
  that (and avoids dropping an active tunnel). Apply service changes manually with
  `sudo systemctl restart forticlient`.
- **`libnotify`.** Without `libnotify.so.4` the tray (`fortitray`) crashes on
  start — and the tray is what brokers SAML, so SSO silently never happens.
- **The SAML deep-link — the big one.** When a tunnel needs SAML, `fortitray`
  runs `/usr/bin/xdg-open "fabricagent://vpn?tunnelName=…&gateway=…"`. The GUI's
  protocol handler (`handleSAMLVPNAuthentication`) is the **only** thing that
  opens the SAML browser, and it only fires when the GUI binary receives that
  `fabricagent://` URL in `argv` (there is no websocket path for it). On NixOS
  this fails two ways, both fixed here:
  1. `/usr/bin/xdg-open` **doesn't exist** on NixOS — `fortitray` hardcodes that
     absolute path → `execve` fails with `ENOENT` → nothing happens. We add a
     tmpfiles symlink `/usr/bin/xdg-open → /run/current-system/sw/bin/xdg-open`.
  2. Nothing is registered for the `fabricagent://` / `forticlient://` URL
     schemes. We register a tiny handler that forwards the deep-link to the GUI
     and set it as the default via `xdg.mime.defaultApplications`.

  Without both, the connection just sits at *Connecting* with no window — the
  symptom that stumped earlier attempts.
- **gnome-keyring.** FortiClient execs `gnome-keyring-daemon` for its keystore.
  On a KDE/kwallet system that's missing; we enable gnome-keyring + PAM unlock.
  It's optional — the VPN works without it (you just can't save credentials), and
  the PAM unlock takes effect after a fresh graphical login.

### Known limitations

- **`x86_64-linux` only** (FortiClient ships no other Linux arch).
- **SAML needs a graphical session that honours XDG autostart.** The tray fires
  the SAML deep-link, and it's started via `/etc/xdg/autostart`. Most DEs (KDE,
  GNOME, XFCE…) honour this; **tiling/Wayland WMs (sway, Hyprland, river, bare
  WMs) often don't**, so you must start `forticlient-tray` yourself (e.g. from
  your compositor config). Without it, SAML silently never opens.
- **SAML 300 s timeout** — if login takes too long the attempt is cancelled; just
  reconnect.
- **The Fortinet download URL will eventually 404** as old releases are rotated —
  bump the version + hash (see [Updating](#updating-the-forticlient-version)).
- Tested on **NixOS 24.05** (KDE/SDDM/Wayland). Other releases may need tweaks
  (e.g. the `services.gnome.gnome-keyring` option path) — the module already
  falls back for the `gnome-keyring` package attribute. The flake pins nixpkgs
  24.05 **only** for `nix flake check` and the standalone package; as a module it
  evaluates against *your* nixpkgs.
- Hardened kernels with user namespaces disabled may break the Electron GUI
  sandbox (the `.deb`'s setuid `chrome-sandbox` bit is intentionally dropped).

## Troubleshooting

- **SAML window never opens:** check `/usr/bin/xdg-open` exists and
  `xdg-mime query default x-scheme-handler/fabricagent` returns
  `forticlient-url-handler.desktop`. Make sure the tray is running
  (`pgrep -x fortitray`) — log out/in if `trayAutostart` was just enabled.
- **Daemon logs:** `journalctl -u forticlient` and `/var/log/forticlient/*.log`
  (the IPsec negotiation is in `ipsecvpn.log`).
- **`nixos-rebuild switch` hangs:** an old service instance grabbed the pty;
  ensure you're on a version with `restartIfChanged = false` (this module sets it).

## Disclaimer

This project repackages proprietary Fortinet software and is **not affiliated with
or endorsed by Fortinet**. FortiClient is downloaded from Fortinet's official
repository at build time (this repo hosts **no** Fortinet binaries) and is governed
by Fortinet's own license. **You are responsible for complying with Fortinet's
EULA/licensing for your use.** The Nix code here is MIT-licensed (see
[LICENSE](./LICENSE)). Use at your own risk.

## Acknowledgements

Builds on the NixOS community's prior packaging explorations and
[`nix-ld`](https://github.com/Mic92/nix-ld). PRs welcome — especially version
bumps and testing on other NixOS releases / desktop environments.

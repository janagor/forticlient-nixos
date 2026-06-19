# Contributing

Thanks for helping! This module was developed and verified on a single host
(NixOS 24.05, KDE Plasma + SDDM + Wayland, `x86_64-linux`), so the most valuable
contributions are **reports and fixes from other setups**.

## Especially wanted

- **Other desktop environments / WMs** — does the SAML tray autostart fire on
  GNOME, XFCE, sway, Hyprland, …? If not, what did you do to start
  `forticlient-tray`? (See the autostart caveat in the README.)
- **Other NixOS releases** (unstable, 24.11+) — option-path or package-attribute
  changes (e.g. `gnome-keyring`, `services.gnome.gnome-keyring`).
- **Version bumps** — when Fortinet rotates releases, PR the new `version` +
  `sha256` in `package.nix` (`nix-prefetch-url <deb-url>` for the hash).
- **SSL VPN / username-password / EMS-less** flows — confirmations or fixes.

## Before opening a PR

- `nix flake check` should pass.
- `nix fmt` (nixpkgs-fmt) to keep formatting consistent.
- A NixOS rebuild **build** (not switch) against a config that sets
  `services.forticlient.enable = true` is a good smoke test:
  `nixos-rebuild build -I nixos-config=./test-config.nix`.
- Please note in the PR which DE / display manager / NixOS release you tested on.

## Debugging tips

- Daemon logs: `journalctl -u forticlient` and `/var/log/forticlient/*.log`
  (the IPsec negotiation is in `ipsecvpn.log`).
- SAML not opening? Check `pgrep -x fortitray`, that `/usr/bin/xdg-open` exists,
  and `xdg-mime query default x-scheme-handler/fabricagent`.

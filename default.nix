# NixOS module for the official Fortinet FortiClient VPN client.
#
# Runs the unmodified FortiClient daemons + Electron GUI via nix-ld, materialises
# the FHS paths FortiClient hardcodes, and wires up the bits that make SAML SSO
# actually work on NixOS (the /usr/bin/xdg-open + fabricagent:// URL-scheme dance).
#
# Enable with:  services.forticlient.enable = true;
{ config, pkgs, lib, ... }:

let
  cfg = config.services.forticlient;

  nixLdLib = "/run/current-system/sw/share/nix-ld/lib";

  # Libraries the unmodified FortiClient binaries (daemons + Electron GUI) need,
  # mirroring the .deb's Depends plus the usual Chromium/Electron runtime set.
  baseLibraries = with pkgs; [
    # base set (a superset of nix-ld's defaults that FortiClient relies on)
    zlib
    zstd
    stdenv.cc.cc
    curl
    openssl
    attr
    libssh
    bzip2
    libxml2
    acl
    libsodium
    util-linux
    xz
    systemd
    # FortiClient daemons + GUI
    glib
    glibc
    gtk3
    gdk-pixbuf
    pango
    cairo
    harfbuzz
    atk
    at-spi2-atk
    at-spi2-core
    dbus
    nss
    nspr
    expat
    cups
    libsecret
    libdrm
    mesa
    alsa-lib
    libxkbcommon
    fontconfig
    freetype
    libnotify # fortitray needs libnotify.so.4 — without it the tray crashes and SAML never pops up
    libayatana-appindicator
    xorg.libX11
    xorg.libxcb
    xorg.libX11.dev
    xorg.libXcomposite
    xorg.libXcursor
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXi
    xorg.libXrandr
    xorg.libXrender
    xorg.libXScrnSaver
    xorg.libXtst
    xorg.libxshmfence
  ];

  # gnome-keyring package moved out of the `gnome` scope in newer nixpkgs.
  gnomeKeyringPkg = pkgs.gnome-keyring or pkgs.gnome.gnome-keyring;

  mkNixLdWrapper = name: target: pkgs.writeShellScriptBin name ''
    export NIX_LD="${nixLdLib}/ld.so"
    export NIX_LD_LIBRARY_PATH="${nixLdLib}"
    export XDG_DATA_DIRS="${lib.makeSearchPath "share" [ pkgs.gtk3 pkgs.gsettings-desktop-schemas ]}:''${XDG_DATA_DIRS:-/run/current-system/sw/share}"
    exec ${target} "$@"
  '';

  # CLI: `forticlient ...`. nix-ld env is set inside the wrapper so it also
  # survives `sudo` (which strips it) and non-login shells.
  fctCli = mkNixLdWrapper "forticlient" "/opt/forticlient/forticlient-cli";
  # GUI: the Electron app (and its embedded SAML/SSO browser).
  fctGui = mkNixLdWrapper "forticlient-gui" "/opt/forticlient/forticlient-cli gui";
  # System tray — resident process that brokers SAML SSO requests.
  fctTray = mkNixLdWrapper "forticlient-tray" "/opt/forticlient/fortitray";
  # URL-scheme handler (see below) — forwards the SAML deep-link into the GUI.
  fctUrlHandler = mkNixLdWrapper "forticlient-url-handler" "/opt/forticlient/gui/FortiClient";

  installForticlient = pkgs.writeShellScript "install-forticlient" ''
    set -eu
    export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
    mkdir -p /opt /var/lib/forticlient
    if [ -f /var/lib/forticlient/installed-package ] &&
       [ "$(cat /var/lib/forticlient/installed-package)" = "${cfg.package}" ] &&
       [ -d /opt/forticlient ]; then
      exit 0
    fi
    staging=$(mktemp -d /opt/.forticlient-new.XXXXXXXX)
    trap 'if [ -d "$staging" ]; then rm -rf "$staging"; fi' EXIT
    cp -a ${cfg.package}/opt/forticlient/. "$staging/"
    if [ -d /opt/forticlient ]; then
      # Keep registration data and any locally created files. Package files in
      # the staged release take precedence over old binaries.
      cp -an /opt/forticlient/. "$staging/"
      backup=$(mktemp -d /var/lib/forticlient/backup.XXXXXXXX)
      rmdir "$backup"
      mv /opt/forticlient "$backup"
      if ! mv "$staging" /opt/forticlient; then
        mv "$backup" /opt/forticlient
        exit 1
      fi
    else
      mv "$staging" /opt/forticlient
    fi
    printf '%s\n' '${cfg.package}' > /var/lib/forticlient/installed-package
  '';

  fctDesktop = pkgs.makeDesktopItem {
    name = "forticlient";
    desktopName = "FortiClient";
    comment = "FortiClient VPN (IPsec / SSL VPN with SAML SSO)";
    exec = "${fctGui}/bin/forticlient-gui";
    icon = "${cfg.package}/opt/forticlient/images/Forticlient.png";
    categories = [ "Network" "Security" ];
    startupNotify = false;
  };

  # THE key fix for SAML on NixOS. When a tunnel needs SAML auth, fortitray runs:
  #   /usr/bin/xdg-open "fabricagent://vpn?tunnelName=<t>&gateway=<g>"
  # The GUI's protocol handler (handleSAMLVPNAuthentication) is the ONLY thing
  # that opens the SAML browser, and it only fires when the GUI binary receives
  # that fabricagent:// URL in argv. So we (1) register a handler for the scheme,
  # routing it to the GUI, and (2) provide /usr/bin/xdg-open (which doesn't exist
  # on NixOS — fortitray hardcodes that absolute path). Without both, the SAML
  # request silently goes nowhere and the connection just hangs "Connecting".
  fctUrlDesktop = pkgs.makeDesktopItem {
    name = "forticlient-url-handler";
    desktopName = "FortiClient URL Handler";
    exec = "${fctUrlHandler}/bin/forticlient-url-handler %u";
    noDisplay = true;
    mimeTypes = [ "x-scheme-handler/fabricagent" "x-scheme-handler/forticlient" ];
  };
in
{
  options.services.forticlient = {
    enable = lib.mkEnableOption "the FortiClient VPN client (IPsec/SSL VPN with SAML SSO)";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = ''
        The FortiClient package, unpacked from the official .deb. Override to track
        a different release with `.override { version = "…"; sha256 = "…"; }` — see
        "Updating the FortiClient version" in the README.
      '';
    };

    extraLibraries = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression "[ pkgs.somelib ]";
      description = ''
        Extra libraries to expose to FortiClient through nix-ld. Use this if a
        future FortiClient release pulls in a library not already covered.
      '';
    };

    trayAutostart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Autostart the FortiClient system tray (`fortitray`) on graphical login.
        The tray is what fires the SAML deep-link, so it must be running for SSO
        logins to work. Disable only if you start it some other way.
      '';
    };

    gnomeKeyring = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Enable gnome-keyring for FortiClient's credential keystore. FortiClient
          execs `gnome-keyring-daemon` and expects a "login" collection; without
          it you get a harmless "failed to unlock keyring" warning (the VPN still
          works, you just can't save credentials).
        '';
      };
      pamServices = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "login" ];
        example = [ "login" "sddm" ];
        description = ''
          PAM services to unlock gnome-keyring on login. The default `[ "login" ]`
          only covers TTY login; for graphical login add your display manager's PAM
          service — e.g. `"sddm"`, `"gdm-password"`, or `"greetd"`. The name must
          match an actually-enabled PAM service to have any effect (an unknown name
          is a silent no-op). Takes effect after a fresh login.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
      message = "services.forticlient is only available on x86_64-linux (FortiClient ships x86_64 binaries only).";
    }];

    ###### Run the unmodified glibc binaries ######
    programs.nix-ld.enable = true;
    programs.nix-ld.libraries = baseLibraries ++ cfg.extraLibraries;

    ###### Materialise the FHS paths FortiClient hardcodes ######
    # /opt must be writable (FortiClient writes registration state there).
    # The service installs new releases before starting; tmpfiles seeds state.
    systemd.tmpfiles.rules = [
      "d /etc/forticlient 0755 root root - -"
      "d /var/lib/forticlient 0755 root root - -"
      "d /var/run/forticlient 0755 root root - -"
      # Seed the config/registration DB from the package's init copy (idempotent).
      "C /var/lib/forticlient/config.db 0600 root root - ${cfg.package}/opt/forticlient/.config.db.init"
      # fortitray hardcodes /usr/bin/xdg-open (absent on NixOS) to fire the SAML
      # deep-link. NOTE: this writes a global FHS path; on a stock NixOS nothing
      # else owns /usr/bin/xdg-open, but it's a system-wide side-effect.
      "L+ /usr/bin/xdg-open - - - - /run/current-system/sw/bin/xdg-open"
    ];

    # Route FortiClient's URL schemes to our handler (system-wide default).
    xdg.mime.defaultApplications = {
      "x-scheme-handler/fabricagent" = "forticlient-url-handler.desktop";
      "x-scheme-handler/forticlient" = "forticlient-url-handler.desktop";
    };

    ###### Main scheduler daemon (spawns iked/vpn for IPSec, sslvpn for SSL) ######
    systemd.services.forticlient = {
      description = "FortiClient Scheduler (fctsched)";
      wantedBy = [ "multi-user.target" ];
      requires = [ "dbus.service" ];
      after = [ "dbus.service" "network.target" ];
      # Don't restart on every nixos-rebuild: fctsched does `su - <user>` to launch
      # the tray, which holds the activation pty open and makes interactive
      # `nixos-rebuild switch` hang. This also avoids dropping an active VPN tunnel
      # on unrelated rebuilds. Apply service changes manually with:
      #   sudo systemctl restart forticlient
      restartIfChanged = false;
      stopIfChanged = false;
      serviceConfig = {
        Type = "simple";
        ExecStartPre = installForticlient;
        ExecStart = "/opt/forticlient/fctsched";
        ExecReload = "/bin/kill -HUP $MAINPID";
        Restart = "always";
        RestartSec = 5;
        KillMode = "mixed";
      };
      # System services don't inherit environment.variables, so set nix-ld vars
      # explicitly; PATH gets the runtime tools the VPN daemons shell out to.
      environment = {
        NIX_LD = "${nixLdLib}/ld.so";
        NIX_LD_LIBRARY_PATH = nixLdLib;
      };
      path = with pkgs; [ iptables iproute2 kmod procps ];
    };

    ###### Credential keystore (optional) ######
    services.gnome.gnome-keyring.enable = lib.mkIf cfg.gnomeKeyring.enable true;
    security.pam.services = lib.mkIf cfg.gnomeKeyring.enable
      (lib.genAttrs cfg.gnomeKeyring.pamServices (_: { enableGnomeKeyring = true; }));

    ###### CLI / GUI / tray / handler on PATH ######
    environment.systemPackages = [
      fctCli
      fctGui
      fctTray
      fctDesktop
      fctUrlHandler
      fctUrlDesktop
    ] ++ lib.optional cfg.gnomeKeyring.enable gnomeKeyringPkg;

    # Start the tray on graphical login (needed for the SAML SSO popup).
    environment.etc = lib.mkIf cfg.trayAutostart {
      "xdg/autostart/forticlient-tray.desktop".text = ''
        [Desktop Entry]
        Type=Application
        Name=FortiClient Tray
        Exec=${fctTray}/bin/forticlient-tray
        X-GNOME-Autostart-enabled=true
        NoDisplay=true
      '';
    };
  };
}

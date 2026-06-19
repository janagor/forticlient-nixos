# FortiClient (full, EMS-capable) repackaged for NixOS from the official .deb.
#
# We run the UNMODIFIED Debian binaries (via nix-ld, wired up in the module) and
# deliberately do NOT autoPatchelf/strip them: FortiClient is a security product
# that ships md5sums + an exe.manifest and may self-verify, so we keep every
# binary byte-for-byte and let nix-ld supply the loader and libraries at runtime.
{ lib
, stdenv
, fetchurl
, dpkg
, gnutar
, xz
  # Override these to track a different FortiClient (Linux) release. Find newer
  # versions + the matching sha256 at https://repo.fortinet.com/repo/forticlient/
, version ? "7.4.7.1868"
, url ? "https://repo.fortinet.com/repo/forticlient/7.4/ubuntu22/pool/non-free/f/forticlient/forticlient_${version}_amd64.deb"
, sha256 ? "2957adb27aafeb61b22c1b7c2698f1e70f407db4cf70e0c874ed8a0b9b8ab908"
}:

stdenv.mkDerivation {
  pname = "forticlient";
  inherit version;

  src = fetchurl { inherit url sha256; };

  nativeBuildInputs = [ dpkg gnutar xz ];

  # `dpkg-deb -x` forces `tar -p`, which can't restore chrome-sandbox's setuid
  # bit as the non-root Nix builder (→ build failure). Pipe the data tarball
  # through plain tar instead; dropping the setuid bit is harmless because
  # Electron falls back to the user-namespace sandbox on modern kernels.
  unpackPhase = ''
    runHook preUnpack
    mkdir pkg
    dpkg-deb --fsys-tarfile "$src" | tar -x -C pkg --no-same-owner
    runHook postUnpack
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a pkg/opt "$out/opt"
    runHook postInstall
  '';

  # Keep the binaries pristine — nix-ld handles loading.
  dontStrip = true;
  dontPatchELF = true;
  dontFixup = true;

  meta = with lib; {
    description = "Fortinet FortiClient VPN client (IPsec/SSL VPN with SAML SSO), repackaged for NixOS";
    homepage = "https://www.fortinet.com/support/product-downloads/linux";
    license = licenses.unfree; # proprietary Fortinet software; requires allowUnfree
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "forticlient";
  };
}

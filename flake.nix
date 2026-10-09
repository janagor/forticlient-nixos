{
  description = "Official Fortinet FortiClient (IPsec/SSL VPN with SAML SSO) as a NixOS module";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.05";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true; # FortiClient is proprietary
      };
    in
    {
      # The NixOS module. Add to your configuration's imports, then set
      #   services.forticlient.enable = true;
      nixosModules.forticlient = import ./default.nix;
      nixosModules.default = self.nixosModules.forticlient;

      # The repackaged FortiClient derivation, if you want it standalone.
      packages = forAllSystems (system: rec {
        forticlient = (pkgsFor system).callPackage ./package.nix { };
        forticlient-8 = forticlient.override {
          version = "8.0.0.0055";
          url = "https://repo.fortinet.com/repo/forticlient/8.0/ubuntu/pool/non-free/f/forticlient/forticlient_8.0.0.0055_amd64.deb";
          sha256 = "eba230c1b6e6d1ac76b8c77633444ff40410651ee0a5716914cbb2f879f19cd6";
        };
        default = forticlient;
      });

      formatter = forAllSystems (system: (pkgsFor system).nixpkgs-fmt);
    };
}

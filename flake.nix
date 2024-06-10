{
  description = "nix-cleanup is a script that cleans up the nix environment.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.nix-cleanup = pkgs.stdenv.mkDerivation rec {
          pname = "nix-cleanup";
          version = "0.0.1";
          src = ./.;

          buildInputs = [ pkgs.bash ];

          installPhase = ''
            mkdir -p $out/bin
            substitute ${pname}.sh $out/bin/${pname} \
              --replace "/usr/bin/env bash" "${pkgs.bash}/bin/bash"
            chmod +x $out/bin/${pname}
          '';

          shellHook = ''
            export PATH=${pkgs.bash}/bin:$PATH
          '';
        };

        defaultPackage = self.packages.${system}.nix-cleanup;

        defaultApp = {
          type = "app";
          program = "${self.packages.${system}.nix-cleanup}/bin/nix-cleanup";
        };
      });
}


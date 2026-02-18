{
  description = "nix-cleanup is a script that cleans up the nix environment.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        inherit (pkgs) lib;
        flakeCommit = self.rev or (self.dirtyRev or "unknown");
        runtimePackages = [
          pkgs.coreutils
          pkgs.cron
          pkgs.findutils
          pkgs.gawk
          pkgs.gitMinimal
          pkgs.gnugrep
          pkgs.nix
        ];
        qualityOnlyPackages = [
          pkgs.actionlint
          pkgs.bats
          pkgs.deadnix
          pkgs.shellcheck
          pkgs.shfmt
          pkgs.statix
        ];
        qualityPackages = runtimePackages ++ qualityOnlyPackages;
        runtimePath = lib.makeBinPath runtimePackages;
        qualityPath = lib.makeBinPath qualityPackages;
        nix-cleanup-unwrapped = pkgs.stdenvNoCC.mkDerivation rec {
          pname = "nix-cleanup";
          version = "0.0.1";
          src = ./.;

          nativeBuildInputs = [ pkgs.bash ];

          installPhase = ''
            runHook preInstall
            mkdir -p "$out/bin"
            substitute ${pname}.sh "$out/bin/${pname}" \
              --replace-fail "/usr/bin/env bash" "${pkgs.bash}/bin/bash" \
              --replace-fail "__NIX_CLEANUP_FLAKE_COMMIT__" "${flakeCommit}"
            chmod +x "$out/bin/${pname}"
            runHook postInstall
          '';
        };
        nix-cleanup = pkgs.symlinkJoin {
          name = "nix-cleanup";
          paths = [ nix-cleanup-unwrapped ];
          nativeBuildInputs = [ pkgs.makeWrapper ];

          postBuild = ''
            wrapProgram "$out/bin/nix-cleanup" \
              --prefix PATH : "${runtimePath}" \
              --set NIX_CLEANUP_ARG0 nix-cleanup
          '';
        };
        mkRepoCheck = name: command:
          pkgs.runCommand name
            {
              src = ./.;
              nativeBuildInputs = [ pkgs.bash ];
            }
            ''
              export PATH=${qualityPath}:$PATH
              cd "$src"
              ${command}
              touch "$out"
            '';
      in
      {
        packages = {
          inherit nix-cleanup;
          default = nix-cleanup;
        };

        apps.default = {
          type = "app";
          program = "${nix-cleanup}/bin/nix-cleanup";
          meta.description = "Clean dead nix store paths safely";
        };

        checks = {
          bash-syntax = mkRepoCheck "bash-syntax" "bash -n nix-cleanup.sh";
          shellcheck = mkRepoCheck "shellcheck" "shellcheck -x nix-cleanup.sh";
          shfmt = mkRepoCheck "shfmt" "shfmt -d -i 2 -ci -sr nix-cleanup.sh";
          actionlint = mkRepoCheck "actionlint" "actionlint .github/workflows/nix-checks.yml";
          statix = mkRepoCheck "statix" "statix check .";
          deadnix = mkRepoCheck "deadnix" "deadnix .";
          runtime-smoke = mkRepoCheck "runtime-smoke" "env -i HOME=$TMPDIR PATH=/nonexistent ${nix-cleanup}/bin/nix-cleanup --help > /dev/null";
          bats = pkgs.runCommand "bats-tests"
            {
              src = ./.;
              nativeBuildInputs = [ pkgs.bash pkgs.bats ];
              NIX_CLEANUP_BIN = "${nix-cleanup-unwrapped}/bin/nix-cleanup";
            }
            ''
              export PATH=${qualityPath}:$PATH
              cd "$src"
              bats --tap tests/cli.bats
              touch "$out"
            '';
        };

        devShells = {
          runtime = pkgs.mkShell {
            packages = runtimePackages;
            shellHook = ''
              export NIX_CLEANUP_BIN="${nix-cleanup}/bin/nix-cleanup"
            '';
          };
          quality = pkgs.mkShell {
            packages = qualityPackages;
            shellHook = ''
              export NIX_CLEANUP_BIN="${nix-cleanup}/bin/nix-cleanup"
            '';
          };
          default = pkgs.mkShell {
            packages = qualityPackages;
            shellHook = ''
              export NIX_CLEANUP_BIN="${nix-cleanup}/bin/nix-cleanup"
            '';
          };
        };
      });
}

# nix-cleanup
nix-cleanup is a script that cleans up the nix environment

## Run
`nix run 'github:willyrgf/nix-cleanup'`
```
Usage: nix-cleanup [--system] [flake-pkg-name] [nix-store-path]
        --system                cleans up the whole nix-store (nix state)
        flake-pkg-name          cleans up everything related to this package on the nix-store
        nix-store-path          cleans up everything related to a nix-store path
```

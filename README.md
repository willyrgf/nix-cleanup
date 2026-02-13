# nix-cleanup
nix-cleanup is a script that cleans up the nix environment

## Run
`nix run 'github:willyrgf/nix-cleanup'`
```
Usage: nix-cleanup [--system]
        [--older-than 30d]
        [flake-pkg-name]
        [/nix/store/path ...]
        --system                cleans up the whole nix-store (nix state)
        --older-than            cleans up nix-store paths older than the provided duration (example: 30d)
        flake-pkg-name          cleans up everything related to this package on the nix-store
        nix-store-path          cleans up everything related to one or more nix-store paths
```

`nix-cleanup` now skips store paths that are still alive (GC-rooted) and only deletes dead paths.

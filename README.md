# nix-cleanup
nix-cleanup is a script that cleans up the nix environment

## Run
`nix run 'github:willyrgf/nix-cleanup'`
```
nix-cleanup - clean dead nix store paths safely

Usage:
  nix-cleanup [--yes] [--system]
  nix-cleanup [--yes] [--older-than 30d]
  nix-cleanup [--yes] [flake-pkg-name]
  nix-cleanup [--yes] [/nix/store/path ...]
  nix-cleanup --add-cron COMMAND_OR_CRON_ENTRY
  nix-cleanup -h | --help

Options:
  -y, --yes
      Skip deletion confirmation prompts.
  --system
      Clean the whole nix store state.
  --older-than <duration>
      Clean store paths older than the provided duration.
      Format: <number>d (example: 30d).
  --add-cron <command-or-cron-entry>
      Add an entry to root's crontab (sudo required).
      Full cron entries are installed as-is.
      Plain commands are stored as: @daily <command>.
  -h, --help
      Show this help text.

Arguments:
  flake-pkg-name
      Clean everything related to one flake package.
  /nix/store/path ...
      Clean one or more explicit nix store paths.

Notes:
  - --add-cron cannot be combined with cleanup options or arguments.
  - --older-than cannot be combined with package/store path arguments.
  - Non --system cleanup prompts for confirmation before deleting.

Examples:
  nix-cleanup --older-than 30d
  nix-cleanup hello
  nix-cleanup /nix/store/hash-a /nix/store/hash-b
  nix-cleanup --add-cron "nix-cleanup --older-than 30d"
  nix-cleanup --add-cron "0 3 * * * nix-cleanup --older-than 30d"
```

`nix-cleanup` now skips store paths that are still alive (GC-rooted) and only deletes dead paths.

### Cron setup (requires sudo)
Use `--add-cron` to append to root's crontab:
- command only (stored as `@daily`): `nix run .#nix-cleanup -- --add-cron "nix-cleanup --older-than 30d"`
- full cron entry: `nix run .#nix-cleanup -- --add-cron "0 3 * * * nix-cleanup --older-than 30d"`

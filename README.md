# nix-cleanup

`nix-cleanup` is a Bash CLI that removes dead Nix store paths with safe filtering and parallel deletion.

## Run

```bash
nix run 'github:willyrgf/nix-cleanup' -- --help
```

The packaged app is wrapped with a pinned runtime `PATH` so `nix run` does not
depend on ambient host tooling for core commands.

## Runtime Dependencies

Runtime tools are bundled in the app closure and checked at startup:
- `nix`, `nix-store`, `nix-collect-garbage`
- `find`, `xargs`, `mktemp`, `awk`, `grep`
- `cp`, `mv`, `rm`, `cat`, `sleep`, `date`
- `git`, `crontab` (required globally by policy)

Feature-specific host dependency:
- `sudo` is validated when a privileged operation is executed.

## Deterministic Quality Gates

All quality checks are Nix-packaged and pinned by `flake.lock`. CI and local
development should use the same canonical command:

```bash
nix flake check --print-build-logs --show-trace
```

`nix flake check` runs:
- Bash syntax check (`bash -n`)
- Shell lint (`shellcheck`)
- Formatting check (`shfmt -d`)
- GitHub Actions lint (`actionlint`)
- Nix lint (`statix`, `deadnix`)
- CLI behavior tests (`bats tests/cli.bats`)

For interactive local iteration, use the pinned toolchain shell:

```bash
nix develop
```

Additional deterministic shells:

```bash
# Runtime-only commands
nix develop .#runtime

# Runtime + quality tooling
nix develop .#quality
```

## Usage

```text
nix-cleanup - clean dead nix store paths safely
Flake commit: <commit-hash-or-unknown>

Usage:
  nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] --system
  nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] --older-than 30d
  nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] flake-pkg-name
  nix-cleanup [--yes] [--jobs N] [--quick] [--no-gc|--gc] /nix/store/path ...
  nix-cleanup [--yes] [--jobs N] --gc-only
  nix-cleanup --add-cron [COMMAND_OR_CRON_ENTRY]
  nix-cleanup help | -h | --help

Options:
  -y, --yes
      Skip deletion confirmation prompts.
  --system
      Clean all currently dead nix-store paths discovered from /nix/store.
  --older-than <duration>
      Clean dead store paths older than the provided duration.
      Format: <number>d (example: 30d).
  --quick
      One-pass fast cleanup. Deletes dead paths once and skips retry waves.
      Defaults to --system and --no-gc unless target/gc mode is specified.
  --jobs <N>
      Parallel worker count for path filtering and deletion.
      Default: auto (between 4 and 32 based on CPU count).
  --no-gc
      Skip final 'nix-collect-garbage -d'.
  --gc
      Force final 'nix-collect-garbage -d' (overrides --quick default).
  --gc-only
      Run only 'nix-collect-garbage -d'.
  --add-cron <command-or-cron-entry>
      Add an entry to root's crontab (sudo required).
      Full cron entries are installed as-is.
      Plain commands are stored as: @daily <command>.
      Default command when omitted: nix-cleanup --quick --gc --yes --jobs 4
  -h, --help
      Show this help text.
```

## Performance Notes

- `--older-than` now works in a dead-first pipeline:
  - snapshot dead store paths once
  - age-filter only those dead paths in parallel
  - delete in parallel workers
- `--quick` is a fast and safe one-pass delete mode.
- `--quick` with no target defaults to `--system`.
- `--quick` defaults to `--no-gc`; use `--gc` to force final GC.
- `--jobs N` lets you scale parallelism up or down.
- `help` as the first argument behaves like `--help`.

## Examples

```bash
# Fast dead-path cleanup older than 30 days
nix run .#nix-cleanup -- --older-than 30d --quick

# Default quick mode (equivalent target/gc defaults: --system --no-gc)
nix run .#nix-cleanup -- --quick --yes

# More aggressive parallel cleanup of dead paths
nix run .#nix-cleanup -- --system --jobs 16 --yes

# Quick mode with explicit final GC
nix run .#nix-cleanup -- --quick --gc --yes

# Clean package closure candidates without final GC
nix run .#nix-cleanup -- hello --no-gc

# Explicit store paths
nix run .#nix-cleanup -- /nix/store/hash-a /nix/store/hash-b --quick

# Run only garbage collection
nix run .#nix-cleanup -- --gc-only
```

## Cron setup (requires sudo)

Use `--add-cron` to append to root's crontab:

- default command (stored as `@daily`):

```bash
nix run .#nix-cleanup -- --add-cron
```

- command only (stored as `@daily`):

```bash
nix run .#nix-cleanup -- --add-cron "nix-cleanup --quick --gc --yes --jobs 4"
```

- full cron entry:

```bash
nix run .#nix-cleanup -- --add-cron "0 3 * * * nix-cleanup --quick --gc --yes --jobs 4"
```

## Lockfile Policy

- `flake.lock` is the source of truth for tool and dependency versions.
- Update lock inputs only through explicit maintenance changes.
- After any lock update, run:

```bash
nix flake check --print-build-logs --show-trace
```

# Repository Guidelines

## Project Structure & Module Organization
- `nix-cleanup.sh`: main Bash CLI script and all cleanup logic.
- `flake.nix`: Nix packaging and app entrypoint (`.#nix-cleanup`).
- `README.md`: user-facing usage documentation.
- `.github/workflows/nix-checks.yml`: CI workflow that validates `nix run .#nix-cleanup -- --help`.
- `flake.lock`: pinned flake inputs; update only when intentionally bumping dependencies.

This repository is intentionally small; keep new logic close to `nix-cleanup.sh` unless there is a clear reason to split files.

## Build, Test, and Development Commands
- `nix run .#nix-cleanup -- --help`: build and run the app locally via flake output.
- `nix build .#nix-cleanup`: build the package artifact without running cleanup operations.
- `bash -n nix-cleanup.sh`: quick shell syntax check before committing.
- `nix run 'github:willyrgf/nix-cleanup' -- --older-than 30d`: example remote invocation.

Prefer non-destructive checks (`--help`, invalid-flag paths) during development.

## Coding Style & Naming Conventions
- Language: Bash (`#!/usr/bin/env bash`), 2-space indentation.
- Function names use underscore prefix and snake case (example: `_cleanup_older_than`).
- Use `local` inside functions and quote variable expansions (`"$var"`).
- Keep output concise and actionable; report skipped/alive paths explicitly.
- Keep dependencies minimal and listed in `required_packages`.

## Testing Guidelines
- No formal test framework exists yet.
- Minimum validation for changes:
  - `bash -n nix-cleanup.sh`
  - `nix run .#nix-cleanup -- --help`
  - One argument-validation check (example: `--older-than bad`)
- Avoid destructive test runs against a real store unless explicitly intended.

## Commit & Pull Request Guidelines
- Follow short, imperative commit messages (examples from history: `Add --older-than filtering...`, `Skip alive store paths...`).
- Conventional prefixes like `feat:` are acceptable but optional.
- PRs should include:
  - What behavior changed and why.
  - Exact commands used for validation.
  - Any safety impact (especially around deletion and `sudo`).

#!/usr/bin/env bash

_exit_error(){
  echo "ERROR: $@"
  exit 1
}

_arg0(){
  echo -n "$0" | grep -Eo '([a-z]+[-.]?){1,}$'
}

_help(){
  printf "
Usage: $(_arg0) [--system]
\t[--older-than 30d]
\t[flake-pkg-name]
\t[/nix/store/path ...]
\t--system\t\tcleans up the whole nix-store (nix state)
\t--older-than\t\tcleans up nix-store paths older than the provided duration (example: 30d)
\tflake-pkg-name\t\tcleans up everything related to this package on the nix-store
\tnix-store-path\t\tcleans up everything related to one or more nix-store paths
"
}

_confirm_deletion(){
  if [ "${CLEANUP_SYSTEM}" -ne 1 ]; then
    read -r -p "Are you sure you want to delete these paths? (y/N): " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      echo "Aborting."
      exit 1
    fi
  fi
}

_delete_store_paths_from_file() {
  local paths_file=$1
  local path_count
  path_count=$(wc -l < "$paths_file")
  path_count=${path_count//[[:space:]]/}

  if [ -z "$path_count" ] || [ "$path_count" -eq 0 ]; then
    echo "No matching nix-store paths found."
    return 0
  fi

  echo "The following paths will be deleted (${path_count}):"
  sed -n '1,20p' "$paths_file"
  if [ "$path_count" -gt 20 ]; then
    echo "... and $((path_count - 20)) more"
  fi

  _confirm_deletion

  xargs -r -n 200 sudo nix-store --delete < "$paths_file"

  echo "Deleted ${path_count} path(s)."
}

_delete_from_store_path(){
  local store_path=$1
  local referrers_file
  local all_paths_file

  referrers_file=$(mktemp)
  all_paths_file=$(mktemp)

  if ! nix-store --query --referrers-closure "$store_path" > "$referrers_file"; then
    rm -f "$referrers_file" "$all_paths_file"
    _exit_error "store path not found: $store_path"
  fi

  {
    printf '%s\n' "$store_path"
    cat "$referrers_file"
  } | awk 'NF && !seen[$0]++' > "$all_paths_file"

  _delete_store_paths_from_file "$all_paths_file"

  rm -f "$referrers_file" "$all_paths_file"
}

_duration_to_days(){
  local duration=$1

  if [[ "$duration" =~ ^([0-9]+)d$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

_nix_cleanup_system() {
  local all_paths_file
  all_paths_file=$(mktemp)

  echo "Indexing and deleting all nix-store paths..."
  find /nix/store -mindepth 1 -maxdepth 1 -print > "$all_paths_file"
  _delete_store_paths_from_file "$all_paths_file"
  rm -f "$all_paths_file"

  # Perform garbage collection to clean up everything
  sudo nix-collect-garbage -d
}

_cleanup_package() {
  local package_name=$1

  # Get the store path of the package
  local store_path

  store_path=$(nix path-info ".#$package_name" 2>/dev/null || true)
  if [ -z "$store_path" ]; then
    echo "Package $package_name not found."
    exit 1
  fi

  echo "Found store path: $store_path"
  _delete_from_store_path "$store_path"

  # Perform garbage collection to clean up everything
  sudo nix-collect-garbage -d

  echo "Garbage collection complete. Nix store is cleaned up."
}

_cleanup_store_paths() {
  local all_paths_file
  all_paths_file=$(mktemp)

  printf '%s\n' "$@" | awk 'NF && !seen[$0]++' > "$all_paths_file"
  _delete_store_paths_from_file "$all_paths_file"
  rm -f "$all_paths_file"

  sudo nix-collect-garbage -d

  echo "Garbage collection complete. Nix store is cleaned up."
}

_cleanup_older_than() {
  local older_than=$1
  local days
  local older_paths_file

  if ! days=$(_duration_to_days "$older_than"); then
    _exit_error "--older-than expects the format <number>d (example: 30d)"
  fi

  older_paths_file=$(mktemp)

  echo "Indexing nix-store paths older than ${older_than}..."
  find /nix/store -mindepth 1 -maxdepth 1 -mtime +"$days" -print > "$older_paths_file"

  _delete_store_paths_from_file "$older_paths_file"
  rm -f "$older_paths_file"

  sudo nix-collect-garbage -d

  echo "Garbage collection complete. Nix store is cleaned up."
}

_all_are_store_paths() {
  local value
  for value in "$@"; do
    if [[ "$value" != /nix/store/* ]]; then
      return 1
    fi
  done

  return 0
}

export CLEANUP_SYSTEM=0
OLDER_THAN=""
POSITIONAL_ARGS=()

# Ensure required packages is available
required_packages=("nix" "nix-store" "nix-collect-garbage" "find" "xargs" "mktemp" "awk")
for req in "${required_packages[@]}"; do
  if ! type "$req" > /dev/null 2>&1; then
    _exit_error "package required: $req"
  fi
done

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      _help
      exit 0
      ;;
    --system)
      CLEANUP_SYSTEM=1
      shift
      ;;
    --older-than)
      if [ -z "${2:-}" ]; then
        _exit_error "--older-than requires a value (example: 30d)"
      fi
      OLDER_THAN="$2"
      shift 2
      ;;
    --older-than=*)
      OLDER_THAN="${1#*=}"
      shift
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        POSITIONAL_ARGS+=("$1")
        shift
      done
      ;;
    -*)
      _exit_error "unknown option: $1"
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

if [ -n "$OLDER_THAN" ] && [ "${#POSITIONAL_ARGS[@]}" -gt 0 ]; then
  _exit_error "--older-than cannot be combined with package/store path arguments"
fi

if [ -n "$OLDER_THAN" ]; then
  _cleanup_older_than "$OLDER_THAN"
  exit $?
fi

if [ "$CLEANUP_SYSTEM" -eq 1 ]; then
  _nix_cleanup_system
  exit $?
fi

if [ "${#POSITIONAL_ARGS[@]}" -eq 0 ]; then
  _help
  exit 1
fi

if _all_are_store_paths "${POSITIONAL_ARGS[@]}"; then
  _cleanup_store_paths "${POSITIONAL_ARGS[@]}"
  exit $?
fi

if [ "${#POSITIONAL_ARGS[@]}" -gt 1 ]; then
  _exit_error "expected one flake package name or one/more /nix/store/path values"
fi

_cleanup_package "${POSITIONAL_ARGS[0]}"

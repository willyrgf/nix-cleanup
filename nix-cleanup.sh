#!/usr/bin/env bash

_exit_error(){
  echo "ERROR: $@"
  exit 1
}

_arg0(){
  echo -n "$0" | grep -Eo '([a-z]+[-.]?){1,}$'
}

_help(){
  cat <<EOF
nix-cleanup - clean dead nix store paths safely

Usage:
  $(_arg0) [--yes] [--system]
  $(_arg0) [--yes] [--older-than 30d]
  $(_arg0) [--yes] [flake-pkg-name]
  $(_arg0) [--yes] [/nix/store/path ...]
  $(_arg0) --add-cron COMMAND_OR_CRON_ENTRY
  $(_arg0) -h | --help

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
  $(_arg0) --older-than 30d
  $(_arg0) hello
  $(_arg0) /nix/store/hash-a /nix/store/hash-b
  $(_arg0) --add-cron "$(_arg0) --older-than 30d"
  $(_arg0) --add-cron "0 3 * * * $(_arg0) --older-than 30d"
EOF
}

_confirm_deletion(){
  if [ "${ASSUME_YES}" -eq 1 ]; then
    return 0
  fi

  if [ "${CLEANUP_SYSTEM}" -ne 1 ]; then
    read -r -p "Are you sure you want to delete these paths? (y/N): " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      echo "Aborting."
      exit 1
    fi
  fi
}

_ensure_sudo_session() {
  if [ "${SUDO_READY}" -eq 1 ]; then
    return 0
  fi

  # `sudo -H` is valid for command execution, but not for `-v` on all sudo versions.
  sudo -v || _exit_error "sudo authentication failed"
  SUDO_READY=1
}

_count_lines() {
  local file=$1
  local count
  count=$(wc -l < "$file")
  echo "${count//[[:space:]]/}"
}

_delete_log_has_only_alive_errors() {
  local log_file=$1
  local error_lines_file

  error_lines_file=$(mktemp)
  grep -E '^error:' "$log_file" > "$error_lines_file" || true

  if [ ! -s "$error_lines_file" ]; then
    rm -f "$error_lines_file"
    return 1
  fi

  if grep -Fv "since it is still alive." "$error_lines_file" > /dev/null; then
    rm -f "$error_lines_file"
    return 1
  fi

  rm -f "$error_lines_file"
  return 0
}

_filter_deletable_paths() {
  local input_file=$1
  local deletable_file=$2
  local alive_file=$3
  local dead_file

  dead_file=$(mktemp)
  : > "$deletable_file"
  : > "$alive_file"

  _ensure_sudo_session
  sudo -H "$NIX_STORE_BIN" --gc --print-dead > "$dead_file" || {
    rm -f "$dead_file"
    _exit_error "failed to query dead store paths"
  }

  awk -v deletable="$deletable_file" -v alive="$alive_file" '
    NR == FNR {
      if (NF && !seen[$0]++) {
        ordered[++count] = $0
        candidate[$0] = 1
      }
      next
    }
    ($0 in candidate) {
      dead[$0] = 1
    }
    END {
      for (i = 1; i <= count; i++) {
        path = ordered[i]
        if (path in dead) {
          print path >> deletable
        } else {
          print path >> alive
        }
      }
    }
  ' "$input_file" "$dead_file"

  rm -f "$dead_file"
}

_delete_store_paths_from_file() {
  local paths_file=$1
  local path_count
  local deletable_file
  local alive_file
  local deletable_count
  local alive_count
  local pending_file
  local remaining_file
  local retry_deletable_file
  local retry_alive_file
  local delete_log
  local pending_count
  local remaining_count
  local retry_deletable_count
  local deleted_this_pass
  local deleted_count
  local delete_batch_size
  local path

  path_count=$(_count_lines "$paths_file")

  if [ -z "$path_count" ] || [ "$path_count" -eq 0 ]; then
    echo "No matching nix-store paths found."
    return 0
  fi

  deletable_file=$(mktemp)
  alive_file=$(mktemp)
  _filter_deletable_paths "$paths_file" "$deletable_file" "$alive_file"

  deletable_count=$(_count_lines "$deletable_file")
  alive_count=$(_count_lines "$alive_file")

  if [ "$alive_count" -gt 0 ]; then
    echo "Skipping ${alive_count} path(s) that are still alive:"
    sed -n '1,20p' "$alive_file"
    if [ "$alive_count" -gt 20 ]; then
      echo "... and $((alive_count - 20)) more"
    fi
  fi

  if [ "$deletable_count" -eq 0 ]; then
    echo "No deletable (dead) nix-store paths found."
    rm -f "$deletable_file" "$alive_file"
    return 0
  fi

  echo "The following dead paths will be deleted (${deletable_count}):"
  sed -n '1,20p' "$deletable_file"
  if [ "$deletable_count" -gt 20 ]; then
    echo "... and $((deletable_count - 20)) more"
  fi

  _confirm_deletion
  _ensure_sudo_session

  pending_file=$(mktemp)
  cp "$deletable_file" "$pending_file"
  deleted_count=0
  delete_batch_size=200

  while :; do
    pending_count=$(_count_lines "$pending_file")
    if [ "$pending_count" -eq 0 ]; then
      break
    fi

    delete_log=$(mktemp)
    xargs -r -n "$delete_batch_size" sudo -H "$NIX_STORE_BIN" --delete < "$pending_file" > "$delete_log" 2>&1 || true

    remaining_file=$(mktemp)
    while IFS= read -r path; do
      if [ -e "$path" ]; then
        printf '%s\n' "$path" >> "$remaining_file"
      fi
    done < "$pending_file"

    remaining_count=$(_count_lines "$remaining_file")
    deleted_this_pass=$((pending_count - remaining_count))
    deleted_count=$((deleted_count + deleted_this_pass))

    if [ "$remaining_count" -eq 0 ]; then
      rm -f "$pending_file" "$remaining_file" "$delete_log"
      pending_file=""
      break
    fi

    retry_deletable_file=$(mktemp)
    retry_alive_file=$(mktemp)
    _filter_deletable_paths "$remaining_file" "$retry_deletable_file" "$retry_alive_file"
    cat "$retry_alive_file" >> "$alive_file"
    retry_deletable_count=$(_count_lines "$retry_deletable_file")

    if [ "$retry_deletable_count" -eq 0 ]; then
      rm -f "$pending_file" "$remaining_file" "$retry_deletable_file" "$retry_alive_file" "$delete_log"
      pending_file=""
      break
    fi

    if [ "$deleted_this_pass" -eq 0 ] && [ "$delete_batch_size" -gt 1 ]; then
      echo "Retrying remaining dead paths one-by-one to resolve referrer ordering..."
      delete_batch_size=1
    elif [ "$deleted_this_pass" -eq 0 ] && [ "$delete_batch_size" -eq 1 ]; then
      if _delete_log_has_only_alive_errors "$delete_log"; then
        echo "Some paths became alive during deletion. Skipping remaining paths."
        cat "$remaining_file" >> "$alive_file"
        rm -f "$pending_file" "$remaining_file" "$retry_deletable_file" "$retry_alive_file" "$delete_log"
        pending_file=""
        break
      fi

      echo "Delete command output (first 20 lines):"
      sed -n '1,20p' "$delete_log"
      rm -f "$pending_file" "$remaining_file" "$retry_deletable_file" "$retry_alive_file" "$delete_log" "$deletable_file" "$alive_file"
      _exit_error "failed to delete some dead paths (check nix-store roots/referrers)"
    fi

    rm -f "$pending_file" "$remaining_file" "$retry_alive_file" "$delete_log"
    pending_file="$retry_deletable_file"
  done

  alive_count=$(_count_lines "$alive_file")
  if [ "$deleted_count" -lt "$deletable_count" ]; then
    echo "Skipped $((deletable_count - deleted_count)) path(s) that were not deletable at delete time."
  fi

  if [ -n "$pending_file" ]; then
    rm -f "$pending_file"
  fi
  rm -f "$deletable_file" "$alive_file"

  echo "Deleted ${deleted_count} path(s)."
}

_delete_from_store_path(){
  local store_path=$1
  local referrers_file
  local all_paths_file

  referrers_file=$(mktemp)
  all_paths_file=$(mktemp)

  if ! "$NIX_STORE_BIN" --query --referrers-closure "$store_path" > "$referrers_file"; then
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

_valid_cron_entry() {
  local cron_entry=$1
  local field1
  local field2
  local field3
  local field4
  local field5
  local command

  if [[ "$cron_entry" =~ ^@[[:alnum:]_-]+[[:space:]]+.+$ ]]; then
    return 0
  fi

  read -r field1 field2 field3 field4 field5 command <<< "$cron_entry"
  if [ -z "$field1" ] || [ -z "$field2" ] || [ -z "$field3" ] || [ -z "$field4" ] || [ -z "$field5" ] || [ -z "$command" ]; then
    return 1
  fi

  return 0
}

_normalize_cron_entry() {
  local value=$1

  if [ -z "$value" ]; then
    return 1
  fi

  if _valid_cron_entry "$value"; then
    printf '%s\n' "$value"
    return 0
  fi

  printf '@daily %s\n' "$value"
  return 0
}

_add_cron_entry() {
  local value=$1
  local cron_entry
  local existing_crontab_file
  local merged_crontab_file

  if ! command -v crontab > /dev/null 2>&1; then
    _exit_error "package required for --add-cron: crontab"
  fi

  if ! cron_entry=$(_normalize_cron_entry "$value"); then
    _exit_error "--add-cron requires a command or cron entry"
  fi

  _ensure_sudo_session

  existing_crontab_file=$(mktemp)
  merged_crontab_file=$(mktemp)

  if ! sudo -H crontab -l > "$existing_crontab_file" 2>/dev/null; then
    : > "$existing_crontab_file"
  fi

  if grep -Fqx -- "$cron_entry" "$existing_crontab_file"; then
    echo "Cron entry already exists in root crontab."
    rm -f "$existing_crontab_file" "$merged_crontab_file"
    return 0
  fi

  cp "$existing_crontab_file" "$merged_crontab_file"
  printf '%s\n' "$cron_entry" >> "$merged_crontab_file"

  if ! sudo -H crontab "$merged_crontab_file"; then
    rm -f "$existing_crontab_file" "$merged_crontab_file"
    _exit_error "failed to install cron entry"
  fi

  rm -f "$existing_crontab_file" "$merged_crontab_file"
  echo "Installed cron entry in root crontab:"
  echo "$cron_entry"
}

_nix_cleanup_system() {
  local all_paths_file
  all_paths_file=$(mktemp)

  echo "Indexing and deleting all nix-store paths..."
  find /nix/store -mindepth 1 -maxdepth 1 -print > "$all_paths_file"
  _delete_store_paths_from_file "$all_paths_file"
  rm -f "$all_paths_file"

  # Perform garbage collection to clean up everything
  _ensure_sudo_session
  sudo -H "$NIX_COLLECT_GARBAGE_BIN" -d
}

_cleanup_package() {
  local package_name=$1

  # Get the store path of the package
  local store_path

  store_path=$("$NIX_BIN" path-info ".#$package_name" 2>/dev/null || true)
  if [ -z "$store_path" ]; then
    echo "Package $package_name not found."
    exit 1
  fi

  echo "Found store path: $store_path"
  _delete_from_store_path "$store_path"

  # Perform garbage collection to clean up everything
  _ensure_sudo_session
  sudo -H "$NIX_COLLECT_GARBAGE_BIN" -d

  echo "Garbage collection complete. Nix store is cleaned up."
}

_cleanup_store_paths() {
  local all_paths_file
  all_paths_file=$(mktemp)

  printf '%s\n' "$@" | awk 'NF && !seen[$0]++' > "$all_paths_file"
  _delete_store_paths_from_file "$all_paths_file"
  rm -f "$all_paths_file"

  _ensure_sudo_session
  sudo -H "$NIX_COLLECT_GARBAGE_BIN" -d

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

  _ensure_sudo_session
  sudo -H "$NIX_COLLECT_GARBAGE_BIN" -d

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
ADD_CRON_ENTRY=""
ASSUME_YES=0
POSITIONAL_ARGS=()
SUDO_READY=0

# Ensure required packages is available
required_packages=("nix" "nix-store" "nix-collect-garbage" "find" "xargs" "mktemp" "awk" "wc" "sed")
for req in "${required_packages[@]}"; do
  if ! type "$req" > /dev/null 2>&1; then
    _exit_error "package required: $req"
  fi
done

NIX_BIN=$(command -v nix)
NIX_STORE_BIN=$(command -v nix-store)
NIX_COLLECT_GARBAGE_BIN=$(command -v nix-collect-garbage)

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)
      _help
      exit 0
      ;;
    -y|--yes)
      ASSUME_YES=1
      shift
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
    --add-cron)
      shift
      if [ $# -eq 0 ]; then
        _exit_error "--add-cron requires a command or cron entry"
      fi
      ADD_CRON_ENTRY="$*"
      break
      ;;
    --add-cron=*)
      ADD_CRON_ENTRY="${1#*=}"
      if [ -z "$ADD_CRON_ENTRY" ]; then
        _exit_error "--add-cron requires a command or cron entry"
      fi
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

if [ -n "$ADD_CRON_ENTRY" ] && { [ "$CLEANUP_SYSTEM" -eq 1 ] || [ -n "$OLDER_THAN" ] || [ "${#POSITIONAL_ARGS[@]}" -gt 0 ]; }; then
  _exit_error "--add-cron cannot be combined with cleanup options/arguments"
fi

if [ -n "$ADD_CRON_ENTRY" ]; then
  _add_cron_entry "$ADD_CRON_ENTRY"
  exit $?
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

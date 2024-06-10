#!/usr/bin/env bash

_exit_error(){
  echo "ERROR: $@"
  exit 1
}

_arg0(){
  echo -n $0 | grep -Eo '([a-z]+[-.]?){1,}$'
}

_help(){
  printf "
Usage: $(_arg0) [--system] [flake-pkg-name] [nix-store-path]
\t--system\t\tcleans up the whole nix-store (nix state)
\tflake-pkg-name\t\tcleans up everything related to this package on the nix-store
\tnix-store-path\t\tcleans up everything related to a nix-store path
"
}

_delete_from_store_path(){
  STORE_PATH=$1

  # Get all referrers
  REFERRERS=$(nix-store --query --referrers-closure "$STORE_PATH")

  # Combine the store path and its referrers
  ALL_PATHS="$STORE_PATH $REFERRERS"

  echo "The following paths will be deleted (${#ALL_PATHS}):"
  echo "$ALL_PATHS"

  # Confirm before deletion
  if [ ${CLEANUP_SYSTEM} -ne 1 ]; then 
    read -p "Are you sure you want to delete these paths? (y/N): " -r
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      echo "Aborting."
      exit 1
    fi
  fi

  # Delete the store path and its referrers
  sudo nix-store --delete $ALL_PATHS

  echo "Deleted the following paths:"
  echo "$ALL_PATHS"
}

_nix_cleanup_system() {
  echo "Indexing and deleting all nix-store paths..."
  ls -1 -f -q /nix/store/ | grep -v '^\.' |
    xargs -I {} -P 4 $0 /nix/store/{}

  # Perform garbage collection to clean up everything
  sudo nix-collect-garbage -d
}

_cleanup_package() {
  PACKAGE_NAME=$1

  # Get the store path of the package

  STORE_PATH=$(nix path-info .#$PACKAGE_NAME 2> >(grep -Eo '/nix/store/([a-z0-9]+[_.-]?)+'))
  if [ -z "$STORE_PATH" ]; then
    echo "Package $PACKAGE_NAME not found."
    exit 1
  fi

  echo "Found store path: ${STORE_PATH[@]}"
  _delete_from_store_path ${STORE_PATH[@]}

  # Perform garbage collection to clean up everything
  sudo nix-collect-garbage -d

  echo "Garbage collection complete. Nix store is cleaned up."
}

export CLEANUP_SYSTEM=0

# Ensure required packages is available
required_packages=("nix" "nix-store" "nix-collect-garbage")
for req in "${required_packages[@]}"; do
  if ! type ${req} > /dev/null 2>&1; then 
    _exit_error "package required: ${req}"
  fi
done

# Ensure a arg is provided
if [ -z "$1" ]; then
  _help
  exit 1
fi

if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
  _help
  exit 0
fi

if [ "$1" == "--system" ]; then
  CLEANUP_SYSTEM=1
  _nix_cleanup_system
  exit $?
fi


if [[ "$1" =~ "/nix/store" ]]; then
  CLEANUP_SYSTEM=1
  _delete_from_store_path $1
  exit $?
fi


_cleanup_package $@

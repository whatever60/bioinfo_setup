#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Generic bootstrap for Linux, macOS, and WSL.
#
# Responsibilities:
#   1) Ensure Nix is installed.
#   2) Load Nix into the current shell.
#   3) Detect a coarse host-family hint (for distro-specific optional behavior).
#   4) Apply the portable Home Manager flake for the chosen user.
#
# Non-goals:
#   - Create OS users
#   - Change sudoers
#   - Use apt/dnf/brew/nala directly
#   - Hardcode EC2-specific usernames
#
# Those platform-specific concerns belong in the thin launch wrappers, not here.
# -----------------------------------------------------------------------------

# Git flake reference for this config repo.
# Override with the first argument when you want to test another ref/branch.
REPO_REF="${1:-github:whatever60/bioinfo_setup}"

# The target account whose HOME we want to manage.
# - In a local shell, this is usually the current user.
# - Under sudo, SUDO_USER is usually the real interactive user.
# - In cloud wrappers, set TARGET_USER explicitly before calling this script.
TARGET_USER="${TARGET_USER:-${SUDO_USER:-$(id -un)}}"

download() {
  # ----------------------------------------------------------------------------
  # Fetch a URL to stdout using whichever downloader exists.
  # We intentionally avoid package managers here to stay OS-agnostic.
  # ----------------------------------------------------------------------------
  local url="$1"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url"
  else
    echo "Need curl or wget to bootstrap Nix." >&2
    exit 1
  fi
}

ensure_nix() {
  # ----------------------------------------------------------------------------
  # Install Nix only if it is missing.
  #
  # We use the official multi-user installer because it is the standard path on
  # Linux and macOS. If we're not root, we elevate only for the install step.
  # ----------------------------------------------------------------------------
  if command -v nix >/dev/null 2>&1; then
    return
  fi

  if [ -z "${HOME:-}" ]; then
    HOME="$(home_for_user "$(id -un)")"
    export HOME
  fi

  echo "Nix not found; installing it..." >&2

  if [ "$(id -u)" -eq 0 ]; then
    download "https://nixos.org/nix/install" | HOME="$HOME" sh -s -- --daemon
  elif command -v sudo >/dev/null 2>&1; then
    download "https://nixos.org/nix/install" | sudo HOME="$HOME" sh -s -- --daemon
  else
    echo "Nix is missing and sudo is unavailable. Install Nix first." >&2
    exit 1
  fi
}

load_nix() {
  # ----------------------------------------------------------------------------
  # Load Nix into the current shell session after installation.
  #
  # The multi-user installer places this profile hook in a standard location.
  # ----------------------------------------------------------------------------
  if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi

  if ! command -v nix >/dev/null 2>&1; then
    echo "Nix still is not on PATH after installation." >&2
    exit 1
  fi
}

home_for_user() {
  # ----------------------------------------------------------------------------
  # Best-effort cross-platform home-directory lookup.
  # - Linux commonly has getent
  # - macOS commonly has dscl
  # - fallback uses shell expansion
  # ----------------------------------------------------------------------------
  local user_name="$1"

  if command -v getent >/dev/null 2>&1; then
    getent passwd "$user_name" | cut -d: -f6
    return
  fi

  if command -v dscl >/dev/null 2>&1; then
    dscl . -read "/Users/${user_name}" NFSHomeDirectory 2>/dev/null | awk '{print $2}'
    return
  fi

  eval "printf '%s\n' ~${user_name}"
}

detect_host_family() {
  # ----------------------------------------------------------------------------
  # Detect a coarse distro family for optional package choices inside the Nix
  # config.
  #
  # Important:
  #   - Nix already knows the platform (linux vs darwin).
  #   - Nix does NOT inherently know whether Linux is Debian vs Fedora vs Arch.
  #   - We pass this in explicitly as an impure environment hint.
  #
  # We only distinguish "debian" vs "other" here because that is all we need
  # for conditional nala installation.
  # ----------------------------------------------------------------------------
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release

    case " ${ID:-} ${ID_LIKE:-} " in
      *" debian "*|*" ubuntu "*)
        printf '%s\n' "debian"
        return
        ;;
    esac
  fi

  printf '%s\n' "other"
}

apply_home_manager() {
  # ----------------------------------------------------------------------------
  # Apply the Home Manager configuration for the current platform.
  #
  # The flake output names are:
  #   portable-x86_64-linux
  #   portable-aarch64-linux
  #   portable-x86_64-darwin
  #   portable-aarch64-darwin
  #
  # We pass USER and HOME explicitly and use --impure so the flake can read:
  #   - USER
  #   - HOME
  #   - HOST_FAMILY
  #
  # HOST_FAMILY is a small escape hatch for distro-specific optional behavior
  # like "install nala on Debian-family Linux".
  # ----------------------------------------------------------------------------
  local nix_bin
  local target_home
  local system_name
  local flake_target
  local host_family

  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    echo "Target user '${TARGET_USER}' does not exist." >&2
    exit 1
  fi

  target_home="$(home_for_user "$TARGET_USER")"
  if [ -z "${target_home}" ]; then
    echo "Could not determine HOME for '${TARGET_USER}'." >&2
    exit 1
  fi

  nix_bin="$(command -v nix)"
  system_name="$("$nix_bin" eval --impure --raw --expr builtins.currentSystem)"
  flake_target="${REPO_REF}#portable-${system_name}"
  host_family="${HOST_FAMILY:-$(detect_host_family)}"

  echo "Applying Home Manager flake ${flake_target} for user ${TARGET_USER}..." >&2
  echo "Detected host family: ${host_family}" >&2

  if [ "$(id -u)" -eq 0 ] && [ "$TARGET_USER" != "root" ]; then
    su -l "$TARGET_USER" -c "
      env \
        USER='${TARGET_USER}' \
        HOME='${target_home}' \
        HOST_FAMILY='${host_family}' \
        NIX_CONFIG='experimental-features = nix-command flakes' \
        '${nix_bin}' run github:nix-community/home-manager/release-25.05 -- \
          switch --impure --flake '${flake_target}'
    "
  else
    USER="$TARGET_USER" \
    HOME="$target_home" \
    HOST_FAMILY="$host_family" \
    NIX_CONFIG='experimental-features = nix-command flakes' \
    "$nix_bin" run github:nix-community/home-manager/release-25.05 -- \
      switch --impure --flake "$flake_target"
  fi
}

main() {
  # ----------------------------------------------------------------------------
  # Top-level orchestration.
  # ----------------------------------------------------------------------------
  ensure_nix
  load_nix
  apply_home_manager
}

main "$@"

#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# EC2 Linux user-data entrypoint.
#
# Why this file exists:
#   EC2 Linux can run plain shell-script user data directly, so we use a tiny
#   Linux-specific wrapper instead of cloud-init YAML.
#
# What this file should do:
#   - Choose the target login user
#   - Download bootstrap.sh
#   - Hand off to the generic bootstrap logic
#
# What this file should NOT do:
#   - apt install packages
#   - create users
#   - modify sudoers
#
# Those steps are intentionally omitted to keep this wrapper as image-agnostic
# as possible across Debian/Ubuntu/Amazon Linux/RHEL-like images.
# -----------------------------------------------------------------------------

# Defaults for this repository.
REPO_REF="${REPO_REF:-github:whatever60/bioinfo_setup}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://raw.githubusercontent.com/whatever60/bioinfo_setup/main/bootstrap.sh}"

detect_target_user() {
  # ---------------------------------------------------------------------------
  # Best-effort guess for the human login user on a Linux cloud image.
  #
  # We prefer an account with:
  #   - a /home/* home directory
  #   - a real shell (not nologin/false)
  #
  # This is still only a fallback.
  # If your AMI uses a specific username, set TARGET_USER explicitly instead.
  # ---------------------------------------------------------------------------
  awk -F: '
    $6 ~ /^\/home\// &&
    $1 != "nobody" &&
    $7 !~ /(false|nologin)$/ {
      print $1
      exit
    }
  ' /etc/passwd
}

export TARGET_USER="${TARGET_USER:-$(detect_target_user)}"

if [ -z "${TARGET_USER}" ]; then
  echo "Could not determine TARGET_USER automatically." >&2
  echo "Set TARGET_USER explicitly in this script or in your launch template." >&2
  exit 1
fi

echo "EC2 Linux bootstrap target user: ${TARGET_USER}" >&2

# Download and execute the generic bootstrap.
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${BOOTSTRAP_URL}" | bash -s -- "${REPO_REF}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "${BOOTSTRAP_URL}" | bash -s -- "${REPO_REF}"
else
  echo "Need curl or wget in the base image." >&2
  exit 1
fi

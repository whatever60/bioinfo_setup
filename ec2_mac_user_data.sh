#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# EC2 Mac user-data entrypoint.
#
# Why this file exists:
#   EC2 Mac accepts user data too, but macOS instances use ec2-macos-init
#   instead of cloud-init. This wrapper gives EC2 Mac the same "shape" as the
#   Linux wrapper: a tiny platform adapter that hands off to bootstrap.sh.
#
# What this file should do:
#   - Choose the target macOS account
#   - Download bootstrap.sh
#   - Hand off to the generic bootstrap logic
#
# What this file should NOT do:
#   - use brew
#   - create users
#   - change sudoers
#
# Keep it thin and platform-specific only where necessary.
# -----------------------------------------------------------------------------

# Defaults for this repository.
REPO_REF="${REPO_REF:-github:whatever60/bioinfo_setup}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://raw.githubusercontent.com/whatever60/bioinfo_setup/main/bootstrap.sh}"

detect_target_user() {
  # ---------------------------------------------------------------------------
  # Best-effort guess for the human login user on a macOS image.
  #
  # On EC2 Mac, usernames can vary by AMI and release. Set TARGET_USER
  # explicitly if your image uses a specific account and you want zero guessing.
  # ---------------------------------------------------------------------------
  dscl . -list /Users UniqueID 2>/dev/null | awk '
    $2 >= 501 &&
    $1 != "Guest" &&
    $1 != "_guest" &&
    $1 != "nobody" {
      print $1
      exit
    }
  '
}

export TARGET_USER="${TARGET_USER:-$(detect_target_user)}"

if [ -z "${TARGET_USER}" ]; then
  echo "Could not determine TARGET_USER automatically." >&2
  echo "Set TARGET_USER explicitly in this script or in your EC2 user data." >&2
  exit 1
fi

echo "EC2 Mac bootstrap target user: ${TARGET_USER}" >&2

# Download and execute the generic bootstrap.
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${BOOTSTRAP_URL}" | bash -s -- "${REPO_REF}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "${BOOTSTRAP_URL}" | bash -s -- "${REPO_REF}"
else
  echo "Need curl or wget in the base image." >&2
  exit 1
fi

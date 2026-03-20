#!/usr/bin/env bash
set -euo pipefail

# WSL cloud-init user-data script
# Put this in one of the Windows-side paths cloud-init checks, e.g.:
#   %USERPROFILE%\.cloud-init\default.user-data
#
# More specific alternatives also work, such as:
#   %USERPROFILE%\.cloud-init\ubuntu-24.04.user-data
#   %USERPROFILE%\.cloud-init\debian-all.user-data

REPO_REF="${REPO_REF:-github:whatever60/bioinfo_setup}"
BOOTSTRAP_URL="${BOOTSTRAP_URL:-https://raw.githubusercontent.com/whatever60/bioinfo_setup/main/bootstrap.sh}"

# In WSL, it's better to set this explicitly if you know it.
# Otherwise bootstrap.sh will fall back to the current/default user.
export TARGET_USER="${TARGET_USER:-your_wsl_username}"

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "${BOOTSTRAP_URL}" | bash -s -- "${REPO_REF}"
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "${BOOTSTRAP_URL}" | bash -s -- "${REPO_REF}"
else
  echo "Need curl or wget in the WSL distro." >&2
  exit 1
fi

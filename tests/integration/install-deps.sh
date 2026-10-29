#!/usr/bin/env bash
# Packages for tests/integration/run.sh in an Ubuntu 26.04 container (as root),
# shared by the Containerfile and the CI integration jobs.
#   install-deps.sh [USER]   also create USER with passwordless sudo
# Optional packages that the archive may not carry are skipped with a message;
# run.sh then skips the assertions that need them.
set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'

REQUIRED=(dconf-cli dbus libglib2.0-bin libglib2.0-dev-bin gsettings-desktop-schemas
  python3 curl ca-certificates xz-utils zsh gnome-shell-extensions gnome-shell-common
  fontconfig sudo git)
OPTIONAL=(ptyxis yaru-theme-gnome-shell ubuntu-wallpapers-resolute)

if [[ $EUID != 0 ]]; then
  echo "install-deps.sh: run as root (inside the container)" >&2
  exit 2
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends "${REQUIRED[@]}"
skipped=()
for p in "${OPTIONAL[@]}"; do
  if ! apt-get install -y --no-install-recommends "$p"; then skipped+=("$p"); fi
done
if ((${#skipped[@]})); then
  echo "install-deps.sh: skipped optional packages (not available): ${skipped[*]}"
else
  echo "install-deps.sh: all optional packages installed"
fi
rm -rf /var/lib/apt/lists/*

if (($#)); then
  user=$1
  if [[ ! $user =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "install-deps.sh: bad user name: $user" >&2
    exit 2
  fi
  id -u "$user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$user"
  printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" >"/etc/sudoers.d/$user"
  chmod 0440 "/etc/sudoers.d/$user"
fi

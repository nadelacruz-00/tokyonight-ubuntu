#!/usr/bin/env bash
# Packages for tests/integration/run.sh in an Ubuntu 26.04 container (as root),
# shared by the Containerfile and the CI integration jobs. All are required:
# run.sh --system fails without the wallpaper and the Yaru GDM base theme.
#   install-deps.sh [USER]   also create USER with passwordless sudo
set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'

PACKAGES=(dconf-cli dbus libglib2.0-bin libglib2.0-dev-bin gsettings-desktop-schemas
  python3 curl ca-certificates xz-utils zsh ptyxis gnome-shell-extensions gnome-shell-common
  yaru-theme-gnome-shell ubuntu-wallpapers-resolute fontconfig sudo git)

if [[ $EUID != 0 ]]; then
  echo "install-deps.sh: run as root (inside the container)" >&2
  exit 2
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends "${PACKAGES[@]}"
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

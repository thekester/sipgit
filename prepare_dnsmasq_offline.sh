#!/usr/bin/env bash
set -Eeuo pipefail

# Helper to download Debian 12 (bookworm) dnsmasq packages on the host and
# push them into the sip-dhcp container for offline installation.

DOWNLOAD_DIR="${DOWNLOAD_DIR:-./offline-debs}"
CONTAINER_NAME="${CONTAINER_NAME:-sip-dhcp}"

PACKAGES=(
  dnsmasq
  dnsmasq-base
  libjansson4
  libnetfilter-conntrack3
  libnfnetlink0
  libnftables1
  libnftnl11
  runit-helper
  dns-root-data
)

require_cmd() {
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "Missing required command: $cmd" >&2
      exit 1
    fi
  done
}

cleanup_workdir() {
  local dir="$1"
  [[ -n "$dir" && -d "$dir" ]] && rm -rf "$dir"
}

main() {
  require_cmd apt-get lxc

  mkdir -p "$DOWNLOAD_DIR"
  pushd "$DOWNLOAD_DIR" >/dev/null

  WORKDIR=$(mktemp -d)
  trap 'cleanup_workdir "$WORKDIR"' EXIT

  mkdir -p \
    "$WORKDIR/etc/apt/apt.conf.d" \
    "$WORKDIR/etc/apt/preferences.d" \
    "$WORKDIR/var/cache/apt/archives/partial" \
    "$WORKDIR/var/lib/apt/lists/partial" \
    "$WORKDIR/var/log/apt" \
    "$WORKDIR/var/lib/dpkg"
  touch "$WORKDIR/var/lib/dpkg/status"
  touch "$WORKDIR/etc/apt/apt.conf"
  touch "$WORKDIR/var/lib/apt/extended_states"

  cat >"$WORKDIR/etc/apt/sources.list" <<'SRC'
deb http://deb.debian.org/debian bookworm main
deb http://deb.debian.org/debian bookworm-updates main
deb http://security.debian.org/debian-security bookworm-security main
SRC

  cat >"$WORKDIR/apt.conf" <<EOF
Dir "$WORKDIR";
Dir::Etc "$WORKDIR/etc/apt";
Dir::Etc::sourcelist "$WORKDIR/etc/apt/sources.list";
Dir::Etc::sourceparts "-";
Dir::Etc::main "$WORKDIR/etc/apt/apt.conf";
Dir::Etc::parts "$WORKDIR/etc/apt/apt.conf.d";
Dir::Etc::preferences "$WORKDIR/etc/apt/preferences";
Dir::Etc::preferencesparts "$WORKDIR/etc/apt/preferences.d";
Dir::State "$WORKDIR/var/lib/apt";
Dir::State::lists "$WORKDIR/var/lib/apt/lists";
Dir::State::extended_states "$WORKDIR/var/lib/apt/extended_states";
Dir::State::status "$WORKDIR/var/lib/dpkg/status";
Dir::Cache "$WORKDIR/var/cache/apt";
Dir::Cache::archives "$WORKDIR/var/cache/apt/archives";
APT::Get::List-Cleanup "false";
APT::Get::AllowUnauthenticated "true";
APT::Update::AllowUnauthenticated "true";
Acquire::AllowInsecureRepositories "true";
Acquire::AllowDowngradeToInsecureRepositories "true";
Acquire::Languages "none";
Debug::NoLocking "true";
EOF

  echo "Preparing Debian bookworm package metadata"
  env APT_CONFIG="$WORKDIR/apt.conf" apt-get update || true

  rm -f -- *.deb 2>/dev/null || true

  echo "Downloading Debian packages to $DOWNLOAD_DIR"
  for pkg in "${PACKAGES[@]}"; do
    echo "- Fetching $pkg from Debian 12"
    env APT_CONFIG="$WORKDIR/apt.conf" apt-get download "$pkg"
  done

  echo "Pushing packages into container $CONTAINER_NAME"
  for deb in *.deb; do
    echo "  -> $deb"
    lxc file push "$deb" "$CONTAINER_NAME/root/"
  done

  echo "All packages transferred. Inside the container, run:\n"
  cat <<'INST'
sudo dpkg -i /root/*.deb
sudo apt-get install -f -y
INST

  popd >/dev/null
}

main "$@"

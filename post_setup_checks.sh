#!/usr/bin/env bash
set -Eeuo pipefail

# Helper to validate the ToIP setup after running setup_toip_infrastructure.sh

USB_IFACE="${USB_IFACE:-enp0s8}"
LXD_BRIDGE="${LXD_BRIDGE:-lxdbr0}"
DHCP_CONTAINER="${DHCP_CONTAINER:-sip-dhcp}"
ASTERISK_CONTAINER="${ASTERISK_CONTAINER:-}"
ASTERISK_SIP_CONF="${ASTERISK_SIP_CONF:-}"
ASTERISK_EXTENSIONS_CONF="${ASTERISK_EXTENSIONS_CONF:-}"
ASTERISK_VOICEMAIL_CONF="${ASTERISK_VOICEMAIL_CONF:-}"
ASTERISK_SERVICE="${ASTERISK_SERVICE:-asterisk}"
SIP_DEVICES_CSV="${SIP_DEVICES_CSV:-./sip_devices.csv}"
SUMMARY_FILE="${SUMMARY_FILE:-./post_setup_summary.txt}"

SCRIPT_NAME=$(basename "$0")
ASTERISK_TARGET="host"

err() {
  echo "[$SCRIPT_NAME] ERROR: $*" >&2
}

die() {
  err "$*"
  exit 1
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script as root (sudo)."
}

require_cmd() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
  done
}

detect_asterisk_configs() {
  local container
  local base
  local sip_candidate
  local extensions_candidate
  local voicemail_candidate

  if [[ -n "$ASTERISK_SIP_CONF" && -f "$ASTERISK_SIP_CONF" && \
        -n "$ASTERISK_EXTENSIONS_CONF" && -f "$ASTERISK_EXTENSIONS_CONF" && \
        -n "$ASTERISK_VOICEMAIL_CONF" && -f "$ASTERISK_VOICEMAIL_CONF" ]]; then
    ASTERISK_TARGET="host"
    return
  fi

  sip_candidate=${ASTERISK_SIP_CONF:-}
  if [[ -z "$sip_candidate" ]]; then
    sip_candidate=$(find /etc -maxdepth 2 -type f -name 'sip.conf' 2>/dev/null | head -n1 || true)
  fi
  if [[ -n "$sip_candidate" ]]; then
    base=$(dirname "$sip_candidate")
    extensions_candidate=${ASTERISK_EXTENSIONS_CONF:-$base/extensions.conf}
    voicemail_candidate=${ASTERISK_VOICEMAIL_CONF:-$base/voicemail.conf}
    if [[ -f "$sip_candidate" && -f "$extensions_candidate" && -f "$voicemail_candidate" ]]; then
      ASTERISK_SIP_CONF="$sip_candidate"
      ASTERISK_EXTENSIONS_CONF="$extensions_candidate"
      ASTERISK_VOICEMAIL_CONF="$voicemail_candidate"
      ASTERISK_TARGET="host"
      return
    fi
  fi

  if [[ -z "$ASTERISK_CONTAINER" ]]; then
    if command -v lxc >/dev/null 2>&1; then
      while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        if lxc exec "$container" -- test -f /etc/asterisk/sip.conf && \
           lxc exec "$container" -- test -f /etc/asterisk/extensions.conf && \
           lxc exec "$container" -- test -f /etc/asterisk/voicemail.conf; then
          ASTERISK_CONTAINER="$container"
          break
        fi
      done < <(lxc list -c n --format csv 2>/dev/null)
    fi
  fi
  container="$ASTERISK_CONTAINER"

  if [[ -n "$container" ]]; then
    ASTERISK_SIP_CONF="${ASTERISK_SIP_CONF:-/etc/asterisk/sip.conf}"
    ASTERISK_EXTENSIONS_CONF="${ASTERISK_EXTENSIONS_CONF:-/etc/asterisk/extensions.conf}"
    ASTERISK_VOICEMAIL_CONF="${ASTERISK_VOICEMAIL_CONF:-/etc/asterisk/voicemail.conf}"
    if lxc exec "$container" -- test -f "$ASTERISK_SIP_CONF" && \
       lxc exec "$container" -- test -f "$ASTERISK_EXTENSIONS_CONF" && \
       lxc exec "$container" -- test -f "$ASTERISK_VOICEMAIL_CONF"; then
      ASTERISK_TARGET="container"
      return
    fi
  fi

  die "Unable to locate Asterisk configuration. Set ASTERISK_* paths or ASTERISK_CONTAINER."
}

asterisk_is_container() {
  [[ ${ASTERISK_TARGET} == "container" ]]
}

run_asterisk_cmd() {
  local command="$1"
  if asterisk_is_container; then
    lxc exec "$ASTERISK_CONTAINER" -- asterisk -rx "$command"
  else
    asterisk -rx "$command"
  fi
}

collect_network_info() {
  echo "== Network Interfaces =="
  ip -br link
  echo
  echo "== Bridge Membership =="
  bridge link
  echo
  echo "== lxdbr0 Addresses =="
  ip addr show "$LXD_BRIDGE"
  echo
}

collect_dhcp_info() {
  echo "== dnsmasq leases (sip-dhcp) =="
  lxc exec "$DHCP_CONTAINER" -- sh -c 'test -f /var/lib/misc/dnsmasq.leases && cat /var/lib/misc/dnsmasq.leases || echo "No leases yet"'
  echo
  echo "== dnsmasq scope =="
  lxc exec "$DHCP_CONTAINER" -- cat /etc/dnsmasq.d/toip.conf
  echo
}

collect_asterisk_info() {
  echo "== Asterisk Peers =="
  if run_asterisk_cmd "sip show peers" >/dev/null 2>&1; then
    run_asterisk_cmd "sip show peers"
  else
    run_asterisk_cmd "pjsip show contacts" || echo "chan_sip and chan_pjsip not available?"
  fi
  echo
  echo "== Asterisk Channels (snapshot) =="
  run_asterisk_cmd "core show channels verbose" || true
  echo
}

print_pjsua_examples() {
  if [[ ! -f "$SIP_DEVICES_CSV" ]]; then
    echo "CSV file $SIP_DEVICES_CSV not found; skipping pjsua examples"
    return
  fi
  mapfile -t accounts < <(tail -n +2 "$SIP_DEVICES_CSV" | head -n4)
  if (( ${#accounts[@]} < 2 )); then
    echo "Not enough entries in $SIP_DEVICES_CSV to build examples"
    return
  fi
  IFS=',' read -r ext1 label1 secret1 _ _ <<<"${accounts[0]}"
  IFS=',' read -r ext2 label2 secret2 _ _ <<<"${accounts[1]}"

  echo "== Sample pjsua commands =="
  cat <<EOF
pjsua --id sip:${ext1}@sip.lab --registrar sip:10.42.0.3 --realm '*' \
      --username ${ext1} --password '${secret1}' sip:${ext2}@sip.lab

pjsua --id sip:${ext2}@sip.lab --registrar sip:10.42.0.3 --realm '*' \
      --username ${ext2} --password '${secret2}' sip:${ext1}@sip.lab

# These sample invocations register each UA against the Asterisk PBX (10.42.0.3)
# from a remote host, then immediately place a call toward another extension.
# Running them validates the exercise requirements: the distant UA authenticates,
# signalling traverses the lxdbr0 bridge (with the USB NIC enslaved), and media
# flows end-to-end between two SIP endpoints provisioned via the generated
# accounts.
EOF
  echo
}

main() {
  require_root
  require_cmd ip bridge lxc
  detect_asterisk_configs

  {
    echo "Post-setup validation run: $(date)"
    echo
    collect_network_info
    collect_dhcp_info
    collect_asterisk_info
    print_pjsua_examples
    echo "== Provisioning Templates =="
    if [[ -d ./provisioning ]]; then
      ls -1 ./provisioning
    else
      echo "Directory ./provisioning not found (run setup_toip_infrastructure.sh first)"
    fi
    echo
  } | tee "$SUMMARY_FILE"

  echo "[$SCRIPT_NAME] Summary written to $SUMMARY_FILE"
  echo "[$SCRIPT_NAME] Review the output and complete the phone configuration steps described in README.md"
}

main "$@"

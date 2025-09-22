#!/usr/bin/env bash
set -Eeuo pipefail

PROVISION_DIR=${PROVISION_DIR:-./provisioning}
PROVISION_PORT=${PROVISION_PORT:-8080}
DHCP_CONTAINER=${DHCP_CONTAINER:-sip-dhcp}
ASTERISK_CONTAINER=${ASTERISK_CONTAINER:-}
ASTERISK_PBX_IP=${ASTERISK_PBX_IP:-10.42.0.3}
SIP_DEVICES_CSV=${SIP_DEVICES_CSV:-./sip_devices.csv}
SCRIPT_NAME=$(basename "$0")
ASTERISK_TARGET="host"
HTTP_SERVER_PID=""

err() { echo "[$SCRIPT_NAME] ERROR: $*" >&2; }

die() { err "$*"; exit 1; }

require_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script with sudo."; }

detect_asterisk() {
  if [[ -n "$ASTERISK_CONTAINER" ]]; then
    ASTERISK_TARGET="container"
    return
  fi
  if ! command -v lxc >/dev/null 2>&1; then
    ASTERISK_TARGET="host"
    return
  fi
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if lxc exec "$name" -- test -f /etc/asterisk/pjsip.conf ||        lxc exec "$name" -- test -f /etc/asterisk/sip.conf; then
      ASTERISK_CONTAINER="$name"
      ASTERISK_TARGET="container"
      return
    fi
  done < <(lxc list -c n --format csv 2>/dev/null)
  ASTERISK_TARGET="host"
}

run_asterisk_cmd() {
  local cmd="$1"
  if [[ "$ASTERISK_TARGET" == "container" ]]; then
    lxc exec "$ASTERISK_CONTAINER" -- asterisk -rx "$cmd"
  else
    asterisk -rx "$cmd"
  fi
}

start_http_server() {
  if [[ ! -d "$PROVISION_DIR" ]]; then
    echo "Provisioning directory $PROVISION_DIR not found; skipping HTTP server."
    return
  fi
  echo "Serving provisioning templates on http://$(hostname -I | awk '{print $1}'):$PROVISION_PORT/"
  python3 -m http.server "$PROVISION_PORT" --directory "$PROVISION_DIR" >/tmp/assist_phone_http.log 2>&1 &
  HTTP_SERVER_PID=$!
  sleep 1
  echo "HTTP server PID: $HTTP_SERVER_PID (log: /tmp/assist_phone_http.log)"
}

stop_http_server() {
  if [[ -n "$HTTP_SERVER_PID" ]]; then
    kill "$HTTP_SERVER_PID" >/dev/null 2>&1 || true
  fi
}

list_provision_templates() {
  if [[ ! -d "$PROVISION_DIR" ]]; then
    echo "Aucun template de provisioning (relancer setup_toip_infrastructure.sh)."
    return
  fi
  echo "Templates disponibles dans $PROVISION_DIR :"
  ls -1 "$PROVISION_DIR"
}

show_pjsua_examples() {
  if [[ ! -f "$SIP_DEVICES_CSV" ]]; then
    echo "CSV $SIP_DEVICES_CSV introuvable."
    return
  fi
  mapfile -t accounts < <(tail -n +2 "$SIP_DEVICES_CSV")
  if (( ${#accounts[@]} < 2 )); then
    echo "Pas assez d'extensions pour générer des commandes pjsua."
    return
  fi
  echo "Commandes pjsua suggérées :"
  for entry in "${accounts[@]}"; do
    IFS=',' read -r ext label secret device device_ip <<<"$entry"
    printf 'pjsua --id sip:%s@%s --registrar sip:%s --realm '*' \
      --username %s --password '%s' sip:%s@%s
'       "$ext" "$ASTERISK_PBX_IP" "$ASTERISK_PBX_IP" "$ext" "$secret" "$ext" "$ASTERISK_PBX_IP"
  done | head -n 4
}

print_next_steps() {
  cat <<EOF
Étapes recommandées :
  1. Importer ou recopier les templates depuis le serveur HTTP ci-dessus dans chaque téléphone/ATA.
  2. Brancher les terminaux sur le LAN lxdbr0 et vérifier les baux :
       sudo lxc exec $DHCP_CONTAINER -- tail -f /var/log/syslog
  3. Vérifier les enregistrements côté Asterisk :
EOF
  if [[ "$ASTERISK_TARGET" == "container" ]]; then
    echo "       sudo lxc exec $ASTERISK_CONTAINER -- asterisk -rx "pjsip show contacts""
  else
    echo "       sudo asterisk -rx "pjsip show contacts""
  fi
  cat <<'EOF'
  4. Lancer les commandes pjsua listées ci-dessous depuis un hôte distant pour valider signalisation et média.
EOF
}

main() {
  require_root
  detect_asterisk
  trap stop_http_server EXIT
  start_http_server
  echo
  list_provision_templates
  echo
  print_next_steps
  echo
  show_pjsua_examples
}

main "$@"

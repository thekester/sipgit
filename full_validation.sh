#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(dirname "$0")"
SIM="$ROOT_DIR/simulate_softphones.sh"
POST="$ROOT_DIR/post_setup_checks.sh"
ASTERISK_CONTAINER="${ASTERISK_CONTAINER:-asterisk01}"
CSV="${SIP_DEVICES_CSV:-./sip_devices.csv}"
REPORT_FILE="${TOIP_REPORT:-./bilan.txt}"
PBX_IP="${ASTERISK_PBX_IP:-10.42.0.3}"
REGISTRATION_TIMEOUT="${REGISTRATION_TIMEOUT:-20}"
SIM_GLOBAL_LOG="${PJSUA_GLOBAL_LOG:-$ROOT_DIR/.pjsua_sessions/simulate_softphones.log}"

CALL_PAIRS=(
  "2001:2002:30"
  "2003:2004:30"
  "2005:2006:30"
  "2007:2008:30"
  "2009:2001:30"
)

declare -A CALL_OUT_STATUS
declare -A CALL_IN_STATUS
declare -A REG_STATUS

log() {
  echo "[full_validation] $*" | tee -a "$REPORT_FILE"
}

err() { log "ERROR: $*" >&2; }

die() { err "$*"; exit 1; }

run_and_capture() {
  log "> $*"
  "$@" 2>&1 | tee -a "$REPORT_FILE"
  return ${PIPESTATUS[0]}
}

ensure_exec() {
  local file="$1"
  [[ -x "$file" ]] || die "Required script $file not executable"
}

discover_pbx_ip() {
  if ping -c1 -W1 "$PBX_IP" >/dev/null 2>&1; then
    log "PBX $PBX_IP reachable (ping)"
    return
  fi

  if command -v lxc >/dev/null 2>&1; then
    local candidate
    candidate=$(lxc list "$ASTERISK_CONTAINER" -c 4 --format csv 2>/dev/null | head -n1 | sed 's/[[:space:]].*//')
    if [[ -n "$candidate" ]]; then
      if ping -c1 -W1 "$candidate" >/dev/null 2>&1; then
        PBX_IP="$candidate"
        log "Detected PBX IP $PBX_IP via container $ASTERISK_CONTAINER"
        return
      fi
    fi
  fi

  log "Warning: unable to reach PBX $PBX_IP via ping"
}

: >"$REPORT_FILE"
log "===== ToIP Validation Report ====="
log "Date: $(date)"

ensure_exec "$SIM"
[[ -x "$POST" ]] || log "Warning: $POST not executable, skipping post checks"

discover_pbx_ip
export ASTERISK_PBX_IP="$PBX_IP"
export ASTERISK_CONTAINER

log "Starting all simulated endpoints"
run_and_capture sudo env "ASTERISK_PBX_IP=$PBX_IP" "ASTERISK_CONTAINER=$ASTERISK_CONTAINER" "$SIM" start-all || log "start-all returned non-zero"

sleep 2

log "Waiting for endpoint registrations (timeout ${REGISTRATION_TIMEOUT}s)"
mapfile -t ALL_EXTENSIONS < <(tail -n +2 "$CSV" | awk -F',' 'NF>0 {print $1}')
for ext in "${ALL_EXTENSIONS[@]}"; do
  [[ -n "$ext" ]] || continue
  if run_and_capture sudo env "ASTERISK_PBX_IP=$PBX_IP" "ASTERISK_CONTAINER=$ASTERISK_CONTAINER" "$SIM" wait-registration "$ext" "$REGISTRATION_TIMEOUT"; then
    REG_STATUS[$ext]="ok"
  else
    status=$?
    case $status in
      1) REG_STATUS[$ext]="timeout" ;;
      2) REG_STATUS[$ext]="failed" ;;
      *) REG_STATUS[$ext]="error" ;;
    esac
    log "Registration status for $ext: ${REG_STATUS[$ext]}"
  fi
  sleep 1
done

for entry in "${CALL_PAIRS[@]}"; do
  IFS=':' read -r caller callee duration <<<"$entry"
  log "Calling $callee from $caller for ${duration}s"
  if [[ "${REG_STATUS[$caller]:-}" != "ok" ]]; then
    log "Skipping call (caller $caller registration ${REG_STATUS[$caller]:-unknown})"
    CALL_OUT_STATUS[$caller]="SKIPPED"
    CALL_IN_STATUS[$callee]="SKIPPED"
    continue
  fi
  if [[ "${REG_STATUS[$callee]:-}" != "ok" ]]; then
    log "Skipping call (callee $callee registration ${REG_STATUS[$callee]:-unknown})"
    CALL_OUT_STATUS[$caller]="SKIPPED"
    CALL_IN_STATUS[$callee]="SKIPPED"
    continue
  fi
  if run_and_capture sudo env "ASTERISK_PBX_IP=$PBX_IP" "ASTERISK_CONTAINER=$ASTERISK_CONTAINER" "$SIM" call "$caller" "$callee" "$duration"; then
    CALL_OUT_STATUS[$caller]="OK"
    CALL_IN_STATUS[$callee]="OK"
  else
    CALL_OUT_STATUS[$caller]="FAIL"
    CALL_IN_STATUS[$callee]="FAIL"
    log "Call $caller->$callee returned non-zero"
  fi
  sleep 2
done

log "Configuration checklist"
log "- DHCP container: sip-dhcp (dnsmasq) supplies 10.42.0.50-99"
if [[ -d "$ROOT_DIR/provisioning" && -f "$CSV" ]]; then
  log "- Provisioning templates par modèle :"
  while IFS=',' read -r ext label _secret device _ip; do
    [[ -n "$ext" ]] || continue
    [[ "$ext" == "extension" ]] && continue
    template=$(ls "$ROOT_DIR"/provisioning/*_${ext}.cfg 2>/dev/null | head -n1)
    if [[ -n "$template" ]]; then
      template=$(basename "$template")
    else
      template="(absent)"
    fi
    pid_file=".pjsua_sessions/${ext}.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
      endpoint_state="running"
    else
      endpoint_state="stopped"
    fi
    reg_state=${REG_STATUS[$ext]:-"n/a"}
    out_state=${CALL_OUT_STATUS[$ext]:-"n/a"}
    in_state=${CALL_IN_STATUS[$ext]:-"n/a"}
    log "    • Extension $ext ($label / $device) : template=$template, softphone=$endpoint_state, registration=$reg_state, call_out=$out_state, call_in=$in_state"
  done < "$CSV"
else
  log "- Provisioning directory or CSV missing"
fi

log "Current softphone status"
run_and_capture sudo env "ASTERISK_PBX_IP=$PBX_IP" "ASTERISK_CONTAINER=$ASTERISK_CONTAINER" "$SIM" status || log "Status command returned non-zero"

log "Asterisk contacts (pjsip show contacts)"
run_and_capture sudo lxc exec "$ASTERISK_CONTAINER" -- asterisk -rx "pjsip show contacts" || log "Unable to run pjsip show contacts"

if [[ -x "$POST" ]]; then
  log "Running post_setup_checks.sh for detailed summary"
  run_and_capture sudo "$POST" || log "post_setup_checks.sh returned non-zero"
fi

log "Full validation sequence complete"
log "Report saved to $REPORT_FILE"
log "Detailed softphone log: $SIM_GLOBAL_LOG (fallback: /tmp/simulate_softphones.log)"

log "\nRésumé des validations :"
log "1. Comptes SIP auto-générés via setup_toip_infrastructure.sh (voir sip_devices.csv)"
log "2. Provisioning par modèle (fichiers ./provisioning/*_<extension>.cfg) et serveur HTTP assist_phone_setup.sh"
log "3. DHCP dnsmasq dans le conteneur sip-dhcp, scope 10.42.0.50-0.99"
log "4. Enregistrement & appels simulés via simulate_softphones.sh (statuts et résultats ci-dessus)"
log "5. Vérifications Asterisk (pjsip show contacts) et post_setup_checks.sh"

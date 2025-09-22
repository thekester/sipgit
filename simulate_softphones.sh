#!/usr/bin/env bash
set -Eeuo pipefail

PBX_IP="${ASTERISK_PBX_IP:-10.42.0.3}"
CSV="${SIP_DEVICES_CSV:-./sip_devices.csv}"
SESS_DIR="${PJSUA_SESSION_DIR:-.pjsua_sessions}"
DEFAULT_DURATION="${PJSUA_CALL_DURATION:-30}"
GLOBAL_LOG="${PJSUA_GLOBAL_LOG:-${SESS_DIR}/simulate_softphones.log}"
ASTERISK_CONTAINER="${ASTERISK_CONTAINER:-asterisk01}"
BASE_LOCAL_PORT=${PJSUA_BASE_PORT:-6000}
CALL_BASE_LOCAL_PORT=${PJSUA_CALL_BASE_PORT:-}

if [[ -z "$CALL_BASE_LOCAL_PORT" ]]; then
  CALL_BASE_LOCAL_PORT=$(( BASE_LOCAL_PORT + 1000 ))
fi

compute_local_port() {
  local ext="$1" base="$2" ext_num offset hash
  offset=0
  if [[ "$ext" =~ ^[0-9]+$ ]]; then
    ext_num=$((10#$ext))
    offset=$(( ext_num - 2000 ))
    if (( offset < 0 )); then
      offset=$ext_num
    fi
  else
    hash=$(printf '%s' "$ext" | cksum | awk '{print $1}')
    offset=$(( hash % 1000 ))
  fi

  base=$((10#$base))
  echo $(( base + offset ))
}

SCRIPT_NAME=$(basename "$0")

err() { echo "[$SCRIPT_NAME] ERROR: $*" >&2; }

die() { err "$*"; exit 1; }

init_logging() {
  local attempt="$GLOBAL_LOG" log_dir
  log_dir=$(dirname "$attempt")
  mkdir -p "$log_dir" 2>/dev/null || true
  if touch "$attempt" 2>/dev/null; then
    GLOBAL_LOG="$attempt"
    return
  fi

  attempt="/tmp/simulate_softphones.log"
  log_dir=$(dirname "$attempt")
  mkdir -p "$log_dir" 2>/dev/null || true
  touch "$attempt" 2>/dev/null || die "Unable to create log file at $attempt"
  if [[ "$attempt" != "$GLOBAL_LOG" ]]; then
    printf '[%s] INFO: falling back to log file %s\n' "$SCRIPT_NAME" "$attempt" >&2
  fi
  GLOBAL_LOG="$attempt"
}

log_msg() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$GLOBAL_LOG"
}

detect_pbx_ip() {
  if [[ -n "$PBX_IP" ]] && ping -c1 -W1 "$PBX_IP" >/dev/null 2>&1; then
    log_msg "Using configured PBX IP $PBX_IP"
    return
  fi

  if command -v lxc >/dev/null 2>&1; then
    local candidate
    candidate=$(lxc list "$ASTERISK_CONTAINER" -c 4 --format csv 2>/dev/null | head -n1 | sed 's/[[:space:]].*//')
    if [[ -n "$candidate" ]]; then
      if ping -c1 -W1 "$candidate" >/dev/null 2>&1; then
        PBX_IP="$candidate"
        export ASTERISK_PBX_IP="$PBX_IP"
        log_msg "Autodetected PBX IP $PBX_IP via container $ASTERISK_CONTAINER"
        echo "[$SCRIPT_NAME] autodetected PBX IP: $PBX_IP"
        return
      fi
    fi
  fi

  log_msg "Unable to verify PBX IP (current value: ${PBX_IP:-unset})"
}

require_pjsua() { command -v pjsua >/dev/null 2>&1 || die "pjsua not found. Install it (sudo apt install -y pjsua)."; }

load_account() {
  local ext="$1"
  local line
  line=$(awk -F',' -v ext="$ext" 'NR>1 && $1==ext {print $0}' "$CSV") || true
  [[ -n "$line" ]] || die "Extension $ext not found in $CSV"
  IFS=',' read -r _ext label secret device device_ip <<<"$line"
  EXT_INFO_EXTENSION="$ext"
  EXT_INFO_LABEL="$label"
  EXT_INFO_SECRET="$secret"
  EXT_INFO_DEVICE="$device"
  EXT_INFO_IP="$device_ip"
}

start_endpoint() {
  local ext="$1"
  load_account "$ext"
  mkdir -p "$SESS_DIR"
  local log="$SESS_DIR/${ext}.log"
  local pid_file="$SESS_DIR/${ext}.pid"
  local local_port

  if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
    echo "[$ext] already running (PID $(cat "$pid_file"))"
    log_msg "[$ext] start skipped - already running with PID $(cat "$pid_file")"
    return
  fi

  local_port=$(compute_local_port "$ext" "$BASE_LOCAL_PORT")

  : >"$log"
  echo "[$ext] starting background pjsua (log: $log)"
  log_msg "[$ext] launching pjsua (log: $log)"
  nohup pjsua \
    --null-audio \
    --auto-answer=200 \
    --log-level=3 \
    --id "sip:${ext}@${PBX_IP}" \
    --registrar "sip:${PBX_IP}" \
    --realm '*' \
    --username "$ext" \
    --password "$EXT_INFO_SECRET" \
    --local-port "$local_port" \
    --no-cli-console \
    < /dev/null \
    >"$log" 2>&1 &
  echo $! >"$pid_file"
  log_msg "[$ext] pjsua started with PID $(cat "$pid_file")"
  sleep 1

  if ! kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
    echo "[$ext] failed to start pjsua (see $log)"
    log_msg "[$ext] pjsua exited shortly after start"
    rm -f "$pid_file"
    return 1
  fi
}

stop_endpoint() {
  local ext="$1"
  local pid_file="$SESS_DIR/${ext}.pid"
  if [[ -f "$pid_file" ]]; then
    local pid=$(cat "$pid_file")
    if kill -0 "$pid" >/dev/null 2>&1; then
      echo "[$ext] stopping pjsua (PID $pid)"
      kill "$pid" >/dev/null 2>&1 || true
      log_msg "[$ext] sent SIGTERM to PID $pid"
    fi
    rm -f "$pid_file"
    log_msg "[$ext] session pid file removed"
  else
    echo "[$ext] no session pid file found"
    log_msg "[$ext] stop requested but no pid file"
  fi
}

start_all() {
  tail -n +2 "$CSV" | while IFS=',' read -r ext _label _secret _device _ip; do
    [[ -n "$ext" ]] || continue
    log_msg "Scheduling start for extension $ext"
    if ! start_endpoint "$ext"; then
      err "Failed to start extension $ext. Check $SESS_DIR/${ext}.log"
    fi
  done
}

stop_all() {
  if [[ ! -d "$SESS_DIR" ]]; then
    echo "No sessions directory $SESS_DIR"
    return
  fi
  for pid_file in "$SESS_DIR"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    local ext
    ext=$(basename "$pid_file" .pid)
    log_msg "Stopping extension $ext"
    stop_endpoint "$ext"
  done
}

status_all() {
  printf "%-6s %-8s %s\n" "Ext" "State" "PID/Log"
  tail -n +2 "$CSV" | while IFS=',' read -r ext _; do
    [[ -n "$ext" ]] || continue
    local pid_file="$SESS_DIR/${ext}.pid"
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" >/dev/null 2>&1; then
      printf "%-6s %-8s %s\n" "$ext" "running" "$(cat "$pid_file") ($SESS_DIR/${ext}.log)"
      log_msg "Status: $ext running (PID $(cat "$pid_file"))"
    else
      printf "%-6s %-8s %s\n" "$ext" "stopped" "-"
      log_msg "Status: $ext stopped"
    fi
  done
}

wait_registration() {
  local ext="$1" timeout="${2:-15}"
  local log="$SESS_DIR/${ext}.log"
  local deadline=$(( $(date +%s) + timeout ))
  log_msg "Waiting for registration of $ext (timeout ${timeout}s)"

  while (( $(date +%s) <= deadline )); do
    if [[ ! -f "$log" ]]; then
      sleep 1
      continue
    fi

    if grep -Eq "SIP registration succeeded|registration success" "$log"; then
      echo "[$ext] registration succeeded"
      log_msg "[$ext] registration succeeded"
      return 0
    fi

    if grep -q "bind() error" "$log"; then
      echo "[$ext] registration failed: local port busy"
      log_msg "[$ext] registration failed due to bind() error"
      return 2
    fi

    if grep -q "SIP registration failed" "$log"; then
      local last_failure
      last_failure=$(grep "SIP registration failed" "$log" | tail -n1)
      last_failure="${last_failure##*: }"
      echo "[$ext] registration failed: $last_failure"
      log_msg "[$ext] registration failed: $last_failure"
      return 2
    fi

    sleep 1
  done

  echo "[$ext] registration timed out after ${timeout}s"
  log_msg "[$ext] registration timed out after ${timeout}s"
  return 1
}

call_pair() {
  local caller="$1" callee="$2" duration="${3:-$DEFAULT_DURATION}"
  load_account "$caller"
  local caller_secret="$EXT_INFO_SECRET"
  load_account "$callee"
  local callee_ext="$EXT_INFO_EXTENSION"
  local caller_port

  caller_port=$(compute_local_port "$caller" "$CALL_BASE_LOCAL_PORT")

  echo "Dialing $callee_ext from $caller (duration ${duration}s)"
  log_msg "Call attempt from $caller to $callee_ext (duration ${duration}s)"
  pjsua \
    --null-audio \
    --auto-answer=200 \
    --duration "$duration" \
    --log-level=4 \
    --id "sip:${caller}@${PBX_IP}" \
    --registrar "sip:${PBX_IP}" \
    --realm '*' \
    --username "$caller" \
    --password "$caller_secret" \
    --local-port "$caller_port" \
    --no-cli-console \
    "sip:${callee_ext}@${PBX_IP}" \
    < /dev/null \
    2>&1 | tee -a "$GLOBAL_LOG"
  local status=${PIPESTATUS[0]}
  log_msg "Call $caller -> $callee_ext finished with status $status"
  return $status
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <command> [args]
Commands:
  start-all             Register all extensions from $CSV using headless pjsua
  stop-all              Stop all background pjsua sessions
  status                Show running endpoints
  start <ext>           Start a single endpoint
  stop <ext>            Stop a single endpoint
  wait-registration <ext> [timeout]
                        Wait for registration success/failure (seconds)
  call <caller> <callee> [duration]
                        Place a call from <caller> to <callee> (seconds)
EOF
}

main() {
  [[ -f "$CSV" ]] || die "CSV file $CSV not found."
  require_pjsua
  init_logging
  detect_pbx_ip

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    start-all)
      start_all
      ;;
    stop-all)
      stop_all
      ;;
    status)
      status_all
      ;;
    start)
      [[ -n "${1:-}" ]] || die "Missing extension"
      start_endpoint "$1"
      ;;
    stop)
      [[ -n "${1:-}" ]] || die "Missing extension"
      stop_endpoint "$1"
      ;;
    wait-registration)
      [[ -n "${1:-}" ]] || die "Missing extension"
      wait_registration "$1" "${2:-15}"
      ;;
    call)
      [[ -n "${1:-}" && -n "${2:-}" ]] || die "Usage: $SCRIPT_NAME call <caller> <callee> [duration]"
      call_pair "$1" "$2" "${3:-$DEFAULT_DURATION}"
      ;;
    "")
      usage
      ;;
    *)
      usage
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"

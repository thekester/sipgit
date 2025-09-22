#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(dirname "$0")"
SIM_SCRIPT="$ROOT_DIR/simulate_softphones.sh"
POST_CHECKS="$ROOT_DIR/post_setup_checks.sh"
ASSIST_SCRIPT="$ROOT_DIR/assist_phone_setup.sh"
ASTERISK_CONTAINER="${ASTERISK_CONTAINER:-asterisk01}"

pause() { read -rp "Press Enter to continue..." _; }

run_cmd() {
  echo -e "\n> $*\n"
  eval "$@"
}

ensure_exec() {
  local file="$1"
  [[ -x "$file" ]] || { echo "Required script $file not executable" >&2; exit 1; }
}

ensure_exec "$SIM_SCRIPT"
ensure_exec "$ASSIST_SCRIPT"
[[ -x "$POST_CHECKS" ]] || echo "Warning: $POST_CHECKS not executable"

while true; do
  clear
  cat <<MENU
=== ToIP Demo Dashboard ===
1. Start all softphones (simulate endpoints)
2. Stop all softphones
3. Show softphone status
4. Call 2001 -> 2002 (30s)
5. Custom call (caller callee [duration])
6. Tail softphone log
7. Run post_setup_checks.sh
8. Run assist_phone_setup.sh
9. Show Asterisk contacts (pjsip show contacts)
q. Quit
MENU
  read -rp "Choice: " choice
  case "$choice" in
    1)
      run_cmd "sudo '$SIM_SCRIPT' start-all"
      pause
      ;;
    2)
      run_cmd "sudo '$SIM_SCRIPT' stop-all"
      pause
      ;;
    3)
      run_cmd "sudo '$SIM_SCRIPT' status"
      pause
      ;;
    4)
      run_cmd "sudo '$SIM_SCRIPT' call 2001 2002 30"
      pause
      ;;
    5)
      read -rp "Caller: " caller
      read -rp "Callee: " callee
      read -rp "Duration (sec) [default 30]: " dur
      run_cmd "sudo '$SIM_SCRIPT' call '$caller' '$callee' '${dur:-30}'"
      pause
      ;;
    6)
      read -rp "Extension to tail: " ext
      log="$ROOT_DIR/.pjsua_sessions/${ext}.log"
      if [[ -f "$log" ]]; then
        echo "Tailing $log (Ctrl+C pour sortir)"
        tail -f "$log"
      else
        echo "Log $log not found."
      fi
      pause
      ;;
    7)
      if [[ -x "$POST_CHECKS" ]]; then
        run_cmd "sudo '$POST_CHECKS'"
      else
        echo "Script $POST_CHECKS introuvable ou non exécutable."
      fi
      pause
      ;;
    8)
      run_cmd "sudo '$ASSIST_SCRIPT'"
      pause
      ;;
    9)
      run_cmd "sudo lxc exec '$ASTERISK_CONTAINER' -- asterisk -rx 'pjsip show contacts'"
      pause
      ;;
    q|Q)
      echo "Bye."
      exit 0
      ;;
    *)
      echo "Unknown choice"
      pause
      ;;
  esac
  sleep 0.2
  clear
done

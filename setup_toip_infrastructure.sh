#!/usr/bin/env bash
set -Eeuo pipefail

# Configuration (override with environment variables before running the script)
USB_IFACE="${USB_IFACE:-}"                     # Example: enx0050b6b12345
LXD_BRIDGE="${LXD_BRIDGE:-lxdbr0}"
BRIDGE_CIDR="${BRIDGE_CIDR:-10.42.0.1/24}"
NETMASK="${NETMASK:-255.255.255.0}"
EXTERNAL_DNS="${EXTERNAL_DNS:-1.1.1.1}"
DHCP_CONTAINER="${DHCP_CONTAINER:-sip-dhcp}"
DHCP_CONTAINER_IMAGE="${DHCP_CONTAINER_IMAGE:-images:debian/12}"
DHCP_CONTAINER_IP="${DHCP_CONTAINER_IP:-10.42.0.2}"
OFFLINE_DIR="${OFFLINE_DIR:-./offline-debs}"
DHCP_RANGE_START="${DHCP_RANGE_START:-10.42.0.50}"
DHCP_RANGE_END="${DHCP_RANGE_END:-10.42.0.99}"
DHCP_LEASE_TIME="${DHCP_LEASE_TIME:-12h}"
PROVISIONING_TFTP="${PROVISIONING_TFTP:-}"       # Optionally set to your provisioning/TFTP server IP
ASTERISK_PBX_IP="${ASTERISK_PBX_IP:-10.42.0.3}"
SIP_DOMAIN="${SIP_DOMAIN:-sip.lab}"
ASTERISK_CONTEXT="${ASTERISK_CONTEXT:-toip-phones}"
VOICEMAIL_CONTEXT="${VOICEMAIL_CONTEXT:-toip-phones}"
ASTERISK_SIP_CONF="${ASTERISK_SIP_CONF:-}"
ASTERISK_EXTENSIONS_CONF="${ASTERISK_EXTENSIONS_CONF:-}"
ASTERISK_VOICEMAIL_CONF="${ASTERISK_VOICEMAIL_CONF:-}"
ASTERISK_CONTAINER="${ASTERISK_CONTAINER:-}"
ASTERISK_SERVICE="${ASTERISK_SERVICE:-asterisk}"
ACCOUNTS_EXPORT="${ACCOUNTS_EXPORT:-./sip_devices.csv}"
ASTERISK_TARGET="host"
PROVISION_DIR="${PROVISION_DIR:-./provisioning}"

# SIP accounts definitions: extension|label|device_key
SIP_ACCOUNTS=(
  "2001|Thomson ST2030|thomson-st2030"
  "2002|Grandstream Budgetone 100 A|grandstream-b100-1"
  "2003|Grandstream Budgetone 100 B|grandstream-b100-2"
  "2004|Aastra 53i|aastra-53i"
  "2005|Aethra Maia XC|aethra-maia-xc"
  "2006|PAP-2T #1 Line 1|pap2t-1"
  "2007|PAP-2T #1 Line 2|pap2t-1"
  "2008|PAP-2T #2 Line 1|pap2t-2"
  "2009|PAP-2T #2 Line 2|pap2t-2"
)

# Physical devices for DHCP reservations: key|ip|mac|label
PHYSICAL_DEVICES=(
  "thomson-st2030|10.42.0.50|${MAC_ST2030:-}|Thomson ST2030"
  "grandstream-b100-1|10.42.0.51|${MAC_GRANDSTREAM_1:-}|Grandstream Budgetone 100 A"
  "grandstream-b100-2|10.42.0.52|${MAC_GRANDSTREAM_2:-}|Grandstream Budgetone 100 B"
  "aastra-53i|10.42.0.53|${MAC_AASTRA_53I:-}|Aastra 53i"
  "aethra-maia-xc|10.42.0.54|${MAC_AETHRA_MAIA_XC:-}|Aethra Maia XC"
  "pap2t-1|10.42.0.55|${MAC_PAP2T_1:-}|Linksys PAP-2T #1"
  "pap2t-2|10.42.0.56|${MAC_PAP2T_2:-}|Linksys PAP-2T #2"
)

SCRIPT_NAME=$(basename "$0")

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

prepare_offline_packages() {
  if [[ -d "$OFFLINE_DIR" && -n "$(ls -1 "$OFFLINE_DIR"/*.deb 2>/dev/null)" ]]; then
    return 0
  fi

  local helper="$(dirname "$0")/prepare_dnsmasq_offline.sh"
  if [[ ! -x "$helper" ]]; then
    echo "[$SCRIPT_NAME] Offline directory empty and helper $helper not executable"
    return 1
  fi

  echo "[$SCRIPT_NAME] Offline directory empty, running $helper"
  "$helper"
}

detect_asterisk_configs() {
  local info
  local base
  local container
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

  if [[ -n "$ASTERISK_CONTAINER" ]]; then
    container="$ASTERISK_CONTAINER"
  else
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
    container="$ASTERISK_CONTAINER"
  fi

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
  [[ ${ASTERISK_TARGET:-host} == "container" ]]
}

asterisk_backup() {
  local path="$1"
  local backup="$2"
  if asterisk_is_container; then
    lxc exec "$ASTERISK_CONTAINER" -- cp "$path" "$backup"
  else
    cp "$path" "$backup"
  fi
}

asterisk_write_file() {
  local path="$1"
  local content="$2"
  local tmp
  if asterisk_is_container; then
    tmp=$(mktemp)
    printf '%s' "$content" >"$tmp"
    lxc file push "$tmp" "$ASTERISK_CONTAINER$path"
    rm -f "$tmp"
  else
    printf '%s' "$content" >"$path"
  fi
}

asterisk_append_if_missing() {
  local path="$1"
  local line="$2"
  if asterisk_is_container; then
    lxc exec "$ASTERISK_CONTAINER" -- sh -c "grep -Fqx '$line' '$path' || echo '$line' >> '$path'"
  else
    grep -Fqx "$line" "$path" || echo "$line" >>"$path"
  fi
}

asterisk_reload() {
  local cmd="systemctl reload $ASTERISK_SERVICE 2>/dev/null || asterisk -rx 'module reload' || true"
  if asterisk_is_container; then
    lxc exec "$ASTERISK_CONTAINER" -- bash -lc "$cmd"
  else
    bash -lc "$cmd"
  fi
}

ensure_provision_dir() {
  mkdir -p "$PROVISION_DIR"
}

write_provision_template() {
  local device_key="$1"
  local extension="$2"
  local label="$3"
  local secret="$4"
  local filename="$PROVISION_DIR/${device_key}_${extension}.cfg"
  local server="$ASTERISK_PBX_IP"
  local domain="$SIP_DOMAIN"
  local content

  case "$device_key" in
    thomson-st2030)
      content=$(cat <<EOF
# Thomson ST2030 – configuration rapide (extension $extension)
identity.display_name="$label"
identity.user_name="$extension"
identity.auth_name="$extension"
identity.password="$secret"
identity.domain="$domain"
identity.proxy_address="$server"
identity.outbound_proxy_enabled="1"
identity.outbound_proxy="$server"
rtp.codec_priority="PCMU,PCMA,GSM"
dtmf.mode="RFC2833"
# Appliquer via l'interface web (Menu > Identity > SIP) puis sauvegarder/redémarrer.
EOF
)
      ;;
    grandstream-b100-1|grandstream-b100-2)
      content=$(cat <<EOF
# Grandstream Budgetone 100 – compte SIP (extension $extension)
AccountActive="Yes"
AccountName="$label"
SIPServer="$server"
SIPUserID="$extension"
AuthenticateID="$extension"
AuthenticatePassword="$secret"
SIPTransport="UDP"
PreferredVocoders="PCMU,PCMA,GSM"
SendDTMFPackets="RFC2833"
# Charger dans l'onglet Account de l'interface web, puis Submit et Reboot.
EOF
)
      ;;
    aastra-53i)
      content=$(cat <<EOF
# Aastra 53i – configuration SIP (extension $extension)
sip line1 screen name: $label
sip line1 user name: $extension
sip line1 auth name: $extension
sip line1 password: $secret
sip line1 display name: $label
sip line1 proxy ip: $server
sip line1 proxy port: 5060
sip line1 registrar ip: $server
sip line1 registrar port: 5060
sip line1 mode: 0   # 0 = SIP
sip line1 dtmf method: rfc2833
sip line1 codec list: pcmu,pcma,gsm
# Importer via le fichier cfg ou saisir dans l'interface (Téléphone > Ligne 1).
EOF
)
      ;;
    aethra-maia-xc)
      content=$(cat <<EOF
# Aethra Maia XC – profil SIP (extension $extension)
[SIPAccount]
DisplayName=$label
UserName=$extension
AuthUserName=$extension
Password=$secret
RegistrarAddress=$server
ProxyAddress=$server
Domain=$domain
DTMFMode=RFC2833
CodecOrder=G711U,G711A,GSM
# Charger via l'interface d'administration (VoIP > Accounts) puis sauvegarder.
EOF
)
      ;;
    pap2t-1|pap2t-2)
      local line_label
      case "$extension" in
        2006) line_label="Line 1" ;;
        2007) line_label="Line 2" ;;
        2008) line_label="Line 1" ;;
        2009) line_label="Line 2" ;;
        *) line_label="Line" ;;
      esac
      content=$(cat <<EOF
# Linksys PAP-2T – $line_label (extension $extension)
Line_Enable: Yes
Proxy: $server
Outbound_Proxy: $server
User_ID: $extension
Password: $secret
Use_DNS_SRV: No
Register_Expires: 3600
Preferred_Codec: G711u
Second_Preferred_Codec: G711a
DTMF_Tx_Method: RFC2833
# Saisir dans l'onglet $line_label du PAP-2T, puis Submit All Changes.
EOF
)
      ;;
    *)
      content=$(cat <<EOF
# Modèle générique – extension $extension
display_name=$label
user=$extension
auth_user=$extension
password=$secret
server=$server
domain=$domain
transport=udp
codecs=PCMU,PCMA,GSM
dtmf=RFC2833
# Remplir les champs équivalents dans l'interface du téléphone.
EOF
)
      ;;
  esac

  printf "%s" "$content" >"$filename"
}

random_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -d '=+/' | cut -c1-20
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c20
  fi
}

ensure_usb_bridged() {
  local iface="$USB_IFACE"
  local bridge="$LXD_BRIDGE"
  [[ -n "$iface" ]] || die "Set USB_IFACE to the USB ethernet interface to bridge."
  ip link show "$iface" >/dev/null 2>&1 || die "Interface $iface not found."
  ip link show "$bridge" >/dev/null 2>&1 || die "Bridge $bridge not found."

  local current_master
  current_master=$(basename "$(readlink -f "/sys/class/net/$iface/master")" 2>/dev/null || true)
  if [[ "$current_master" != "$bridge" ]]; then
    echo "[$SCRIPT_NAME] Attaching $iface to $bridge"
    ip link set "$iface" down
    ip link set "$iface" master "$bridge"
  else
    echo "[$SCRIPT_NAME] $iface already enslaved to $bridge"
  fi
  ip link set "$iface" up
  ip link set "$iface" promisc on
}

configure_lxd_bridge() {
  local bridge="$LXD_BRIDGE"
  local cidr="$BRIDGE_CIDR"
  local gateway=${cidr%%/*}

  echo "[$SCRIPT_NAME] Configuring LXD bridge $bridge ($cidr)"
  lxc network set "$bridge" ipv4.address "$cidr"
  lxc network set "$bridge" ipv4.dhcp false
  lxc network set "$bridge" ipv4.nat false
  lxc network set "$bridge" ipv6.address none
  ip addr show dev "$bridge" | grep -q "$gateway" || ip addr add "$cidr" dev "$bridge" 2>/dev/null || true
}

configure_dhcp_container_network() {
  local name="$1"
  local gateway=${BRIDGE_CIDR%%/*}
  local prefix=${BRIDGE_CIDR##*/}
  local tmpfile

  echo "[$SCRIPT_NAME] Setting static IP $DHCP_CONTAINER_IP/$prefix inside $name"
  lxc start "$name" >/dev/null 2>&1 || true
  lxc exec "$name" -- bash -lc 'mkdir -p /etc/systemd/network'

  tmpfile=$(mktemp)
  cat >"$tmpfile" <<EOF
[Match]
Name=eth0

[Network]
Address=$DHCP_CONTAINER_IP/$prefix
Gateway=$gateway
DNS=$EXTERNAL_DNS
Domains=$SIP_DOMAIN
EOF
  lxc file push "$tmpfile" "$name/etc/systemd/network/10-toip-eth0.network" --uid 0 --gid 0 --mode 0644
  rm -f "$tmpfile"

  lxc exec "$name" -- bash -lc 'rm -f /etc/systemd/network/eth0.network 2>/dev/null || true'
  lxc exec "$name" -- bash -lc 'rm -f /etc/network/interfaces.d/eth0 2>/dev/null || true'
  lxc exec "$name" -- bash -lc 'rm -f /etc/resolv.conf 2>/dev/null || true'

  tmpfile=$(mktemp)
  cat >"$tmpfile" <<EOF
nameserver $EXTERNAL_DNS
search $SIP_DOMAIN
EOF
  lxc file push "$tmpfile" "$name/etc/resolv.conf" --uid 0 --gid 0 --mode 0644
  rm -f "$tmpfile"

  lxc exec "$name" -- bash -lc 'systemctl enable systemd-networkd.service >/dev/null 2>&1 || true'
  lxc exec "$name" -- bash -lc 'systemctl restart systemd-networkd.service'
  sleep 2
}

ensure_dhcp_container() {
  local name="$DHCP_CONTAINER"
  local image="$DHCP_CONTAINER_IMAGE"
  local bridge="$LXD_BRIDGE"

  if ! lxc info "$name" >/dev/null 2>&1; then
    echo "[$SCRIPT_NAME] Creating DHCP container $name from $image"
    lxc launch "$image" "$name" -n "$bridge"
    sleep 5
  else
    echo "[$SCRIPT_NAME] DHCP container $name already exists"
  fi

  lxc config set "$name" boot.autostart true
  configure_dhcp_container_network "$name"

  echo "[$SCRIPT_NAME] Installing dnsmasq inside $name"
  if ! lxc exec "$name" -- which dnsmasq >/dev/null 2>&1; then
    if [[ -d "$OFFLINE_DIR" && -n "$(ls -1 "$OFFLINE_DIR"/*.deb 2>/dev/null)" ]]; then
      echo "[$SCRIPT_NAME] Using offline packages from $OFFLINE_DIR"
      lxc exec "$name" -- sh -c 'rm -f /root/*.deb'
      for deb in "$OFFLINE_DIR"/*.deb; do
        lxc file push "$deb" "$name/root/"
      done
      lxc exec "$name" -- bash -lc 'dpkg -i /root/*.deb || { apt-get install -f -y --no-download && dpkg -i /root/*.deb; }'
    else
      if prepare_offline_packages; then
        echo "[$SCRIPT_NAME] Offline packages populated, retrying"
        lxc exec "$name" -- sh -c 'rm -f /root/*.deb'
        for deb in "$OFFLINE_DIR"/*.deb; do
          lxc file push "$deb" "$name/root/"
        done
        lxc exec "$name" -- bash -lc 'dpkg -i /root/*.deb || { apt-get install -f -y --no-download && dpkg -i /root/*.deb; }'
      else
        echo "[$SCRIPT_NAME] No offline packages available, falling back to apt-get"
        lxc exec "$name" -- bash -lc 'apt-get update && apt-get install -y dnsmasq'
      fi
    fi
  else
    echo "[$SCRIPT_NAME] dnsmasq already installed in $name"
  fi
  lxc exec "$name" -- bash -lc 'systemctl disable --now systemd-resolved.service 2>/dev/null || true'

  local dnsmasq_conf="/etc/dnsmasq.d/toip.conf"
  local gateway=${BRIDGE_CIDR%%/*}

  echo "[$SCRIPT_NAME] Writing dnsmasq configuration"
  lxc exec "$name" -- bash -lc "cat <<'EOF' >$dnsmasq_conf
interface=eth0
bind-interfaces
bogus-priv
quiet-dhcp
quiet-dhcp6
quiet-ra
domain=$SIP_DOMAIN
dhcp-range=$DHCP_RANGE_START,$DHCP_RANGE_END,$NETMASK,$DHCP_LEASE_TIME
dhcp-option=option:router,$gateway
dhcp-option=option:dns-server,$DHCP_CONTAINER_IP
dhcp-option=option:domain-search,$SIP_DOMAIN
server=$EXTERNAL_DNS
EOF"

  if [[ -n "$PROVISIONING_TFTP" ]]; then
    lxc exec "$name" -- bash -lc "echo 'dhcp-option=option:tftp-server,$PROVISIONING_TFTP' >>$dnsmasq_conf"
  fi

  local tmpfile
  tmpfile=$(mktemp)
  {
    for entry in "${PHYSICAL_DEVICES[@]}"; do
      IFS='|' read -r key ip mac label <<<"$entry"
      if [[ -n "$mac" ]]; then
        echo "dhcp-host=$mac,$ip"
      else
        echo "# dhcp-host=<MAC-$key>,$ip  # $label"
      fi
    done
  } >"$tmpfile"
  lxc file push "$tmpfile" "$name$dnsmasq_conf.hosts"
  rm -f "$tmpfile"
  lxc exec "$name" -- bash -lc "cat $dnsmasq_conf.hosts >>$dnsmasq_conf"
  lxc exec "$name" -- rm -f "$dnsmasq_conf.hosts"

  lxc exec "$name" -- bash -lc 'systemctl enable dnsmasq && systemctl restart dnsmasq'
}

configure_asterisk() {
  detect_asterisk_configs

  local sip_conf="$ASTERISK_SIP_CONF"
  local ext_conf="$ASTERISK_EXTENSIONS_CONF"
  local vm_conf="$ASTERISK_VOICEMAIL_CONF"
  local context="$ASTERISK_CONTEXT"
  local vm_context="$VOICEMAIL_CONTEXT"
  local sip_snippet
  local ext_snippet
  local vm_snippet
  local timestamp
  local sip_payload
  local ext_payload
  local vm_payload

  if asterisk_is_container; then
    lxc exec "$ASTERISK_CONTAINER" -- test -f "$sip_conf" || die "Asterisk SIP config $sip_conf not found in container $ASTERISK_CONTAINER"
    lxc exec "$ASTERISK_CONTAINER" -- test -f "$ext_conf" || die "Asterisk extensions config $ext_conf not found in container $ASTERISK_CONTAINER"
    lxc exec "$ASTERISK_CONTAINER" -- test -f "$vm_conf" || die "Asterisk voicemail config $vm_conf not found in container $ASTERISK_CONTAINER"
  else
    [[ -f "$sip_conf" ]] || die "Asterisk SIP config $sip_conf not found"
    [[ -f "$ext_conf" ]] || die "Asterisk extensions config $ext_conf not found"
    [[ -f "$vm_conf" ]] || die "Asterisk voicemail config $vm_conf not found"
  fi

  timestamp=$(date +%Y%m%d%H%M%S)
  sip_snippet="$(dirname "$sip_conf")/sip_phones.conf"
  ext_snippet="$(dirname "$ext_conf")/extensions_phones.conf"
  vm_snippet="$(dirname "$vm_conf")/voicemail_phones.conf"

  echo "[$SCRIPT_NAME] Generating SIP account definitions"

  asterisk_backup "$sip_conf" "$sip_conf.$timestamp.bak"
  asterisk_backup "$ext_conf" "$ext_conf.$timestamp.bak"
  asterisk_backup "$vm_conf" "$vm_conf.$timestamp.bak"

  declare -A devices_labels
  declare -A devices_ips
  for entry in "${PHYSICAL_DEVICES[@]}"; do
    IFS='|' read -r key ip mac label <<<"$entry"
    devices_labels[$key]="$label"
    devices_ips[$key]="$ip"
  done

  printf -v ext_payload '[%s]
; Auto-generated by %s

' "$context" "$SCRIPT_NAME"
  printf -v vm_payload '[%s]
; Auto-generated by %s
' "$vm_context" "$SCRIPT_NAME"
  sip_payload=""

  >"$ACCOUNTS_EXPORT"
  printf 'extension,label,secret,device,device_ip
' >>"$ACCOUNTS_EXPORT"

  ensure_provision_dir

  for entry in "${SIP_ACCOUNTS[@]}"; do
    IFS='|' read -r extension label device_key <<<"$entry"
    local_secret=$(random_secret)
    device_label="${devices_labels[$device_key]:-$device_key}"
    device_ip="${devices_ips[$device_key]:-N/A}"

    printf -v sip_block '[%s]
type=friend
host=dynamic
secret=%s
context=%s
defaultuser=%s
callerid="%s <%s>"
disallow=all
allow=alaw,ulaw,gsm
transport=udp
qualify=yes
dtmfmode=rfc2833
nat=yes
mailbox=%s@%s

'       "$extension" "$local_secret" "$context" "$extension" "$label" "$extension" "$extension" "$vm_context"
    sip_payload+="$sip_block"

    printf -v ext_block 'exten => %s,1,NoOp(%s calling)
exten => %s,n,Dial(SIP/%s,20)
exten => %s,n,VoiceMail(%s@%s,u)
exten => %s,n,Hangup()

'       "$extension" "$label" "$extension" "$extension" "$extension" "$extension" "$vm_context" "$extension"
    ext_payload+="$ext_block"

    printf -v vm_block '%s => 1234,%s,%s@%s
' "$extension" "$label" "$extension" "$SIP_DOMAIN"
    vm_payload+="$vm_block"

    printf '%s,%s,%s,%s,%s
' "$extension" "$label" "$local_secret" "$device_label" "$device_ip" >>"$ACCOUNTS_EXPORT"

    write_provision_template "$device_key" "$extension" "$label" "$local_secret"
  done

  asterisk_write_file "$sip_snippet" "$sip_payload"
  asterisk_write_file "$ext_snippet" "$ext_payload"
  asterisk_write_file "$vm_snippet" "$vm_payload"

  asterisk_append_if_missing "$sip_conf" '#include "sip_phones.conf"'
  asterisk_append_if_missing "$ext_conf" '#include "extensions_phones.conf"'
  asterisk_append_if_missing "$vm_conf" '#include "voicemail_phones.conf"'

  asterisk_reload
}


print_summary() {
  local gateway=${BRIDGE_CIDR%%/*}
  cat <<EOF
[$SCRIPT_NAME] Infrastructure ready.

Network:
  - Bridge $LXD_BRIDGE on $BRIDGE_CIDR (gateway $gateway)
  - DHCP container $DHCP_CONTAINER at $DHCP_CONTAINER_IP (dnsmasq)
  - DHCP scope $DHCP_RANGE_START-$DHCP_RANGE_END, domain $SIP_DOMAIN

Asterisk:
  - Context: $ASTERISK_CONTEXT
  - Accounts exported to $ACCOUNTS_EXPORT
  - Sample reload command: systemctl reload $ASTERISK_SERVICE

Testing from remote host (replace EXT with target extension):
  pjsua --id sip:EXT@$SIP_DOMAIN --registrar sip:$ASTERISK_PBX_IP --realm '*' \\
        --username EXT --password '<secret-from-csv>' sip:OTHER_EXT@$SIP_DOMAIN

Remember to update MAC addresses in environment variables for static leases.
EOF
}

main() {
  require_root
  require_cmd ip lxc systemctl
  ensure_usb_bridged
  configure_lxd_bridge
  ensure_dhcp_container
  configure_asterisk
  print_summary
}

main "$@"

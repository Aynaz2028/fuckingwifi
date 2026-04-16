#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

############################################
# CONFIG
############################################
SESSION_DIR="$PWD/sessions"
LOG_FILE="$SESSION_DIR/activity.log"
mkdir -p "$SESSION_DIR"

############################################
# COLORS
############################################
RED="$(printf '\033[31m')"
GREEN="$(printf '\033[32m')"
YELLOW="$(printf '\033[33m')"
CYAN="$(printf '\033[36m')"
RESET="$(printf '\033[0m')"

############################################
# GLOBAL
############################################
INTERFACE=""

############################################
# LOGGING
############################################
log(){ echo -e "${GREEN}[+]${RESET} $*"; echo "[$(date)] $*" >> "$LOG_FILE"; }
warn(){ echo -e "${YELLOW}[!]${RESET} $*"; echo "[$(date)] WARN: $*" >> "$LOG_FILE"; }
error(){ echo -e "${RED}[-]${RESET} $*"; echo "[$(date)] ERR: $*" >> "$LOG_FILE"; }

############################################
# ROOT CHECK
############################################
require_root(){
    [[ $EUID -ne 0 ]] && { error "Run as root"; exit 1; }
}

############################################
# DEPENDENCIES
############################################
check_dependencies(){
    for cmd in nmcli ip iw; do
        command -v "$cmd" &>/dev/null || warn "$cmd not found"
    done
}

############################################
# NETWORK FIX
############################################
install_network_manager(){
    log "Ensuring NetworkManager..."

    if command -v nmcli &>/dev/null; then
        log "Already installed"
        return
    fi

    if command -v apt &>/dev/null; then
        apt update && apt install -y network-manager
    elif command -v dnf &>/dev/null; then
        dnf install -y NetworkManager
    elif command -v yum &>/dev/null; then
        yum install -y NetworkManager
    else
        warn "Install NetworkManager manually"
        return
    fi

    systemctl enable NetworkManager 2>/dev/null || true
    systemctl start NetworkManager 2>/dev/null || true
}

restart_network(){
    log "Restarting network..."

    if ! command -v nmcli &>/dev/null; then
        install_network_manager
    fi

    if command -v nmcli &>/dev/null; then
        nmcli networking off || true
        sleep 1
        nmcli networking on || true
    else
        warn "Network control not available"
    fi
}

############################################
# INTERFACE
############################################
detect_wifi_interface() {
    INTERFACE=$(nmcli device status | awk '$2=="wifi"{print $1}' | head -n1)

    if [[ -z "$INTERFACE" ]]; then
        warn "No WiFi interface detected"
        return 1
    fi

    log "Auto-detected interface: $INTERFACE"
    return 0
}

select_interface(){
    nmcli device status
    read -rp "Enter WiFi interface: " INTERFACE

    [[ -z "$INTERFACE" ]] && { warn "Invalid"; return; }

    log "Using $INTERFACE"
}

ensure_interface_up(){
    [[ -n "$INTERFACE" ]] && ip link set "$INTERFACE" up 2>/dev/null || true
}

############################################
# SCANNING
############################################
scan_networks(){
    [[ -z "$INTERFACE" ]] && detect_wifi_interface || true

    ensure_interface_up

    log "Scanning..."

    RESULT=$(nmcli -f IN-USE,SSID,BSSID,CHAN,SIGNAL,SECURITY device wifi list)

    if [[ -z "$RESULT" || $(echo "$RESULT" | wc -l) -le 1 ]]; then
        warn "No networks found. Rescanning..."
        nmcli device wifi rescan &>/dev/null
        sleep 2
        nmcli -f IN-USE,SSID,BSSID,CHAN,SIGNAL,SECURITY device wifi list
    else
        echo "$RESULT"
    fi
}

scan_and_save(){
    [[ -z "$INTERFACE" ]] && detect_wifi_interface || true

    OUT="$SESSION_DIR/scan_$(date +%s).txt"

    nmcli -f SSID,BSSID,CHAN,SIGNAL,SECURITY device wifi list > "$OUT"

    log "Saved to $OUT"
}

############################################
# LIVE SCAN
############################################
live_scan(){
    [[ -z "$INTERFACE" ]] && detect_wifi_interface || true

    log "Live scan (Ctrl+C to stop)"
    sleep 1

    while true; do
        clear
        echo "==== LIVE WIFI SCAN ===="
        echo "Interface: $INTERFACE"
        echo "Time: $(date)"
        echo

        nmcli -f IN-USE,SSID,BSSID,CHAN,SIGNAL,SECURITY device wifi list

        sleep 2
    done
}

############################################
# FILTERS
############################################
filter_signal(){
    read -rp "Min signal (0-100): " MIN

    nmcli -f SSID,BSSID,CHAN,SIGNAL,SECURITY device wifi list | \
    awk -v min="$MIN" 'NR==1 || $4 >= min'
}

filter_security(){
    read -rp "Security (WPA2/WPA3/OPEN): " SEC

    nmcli -f SSID,BSSID,CHAN,SIGNAL,SECURITY device wifi list | \
    grep -i "$SEC"
}

advanced_filter(){
    read -rp "Min signal: " MIN
    read -rp "Security (optional): " SEC

    nmcli -f SSID,BSSID,CHAN,SIGNAL,SECURITY device wifi list | \
    awk -v min="$MIN" -v sec="$SEC" '
    NR==1 {print; next}
    $4 >= min {
        if(sec=="" || tolower($5) ~ tolower(sec)) print
    }'
}

############################################
# MENU
############################################
menu(){
while true; do
clear
cat <<EOF
==== WIFI TOOLKIT ====
1) Check Dependencies
2) Fix Network
3) Select Interface
4) Scan Networks
5) Scan & Save
6) Live Scan
7) Filter by Signal
8) Filter by Security
9) Advanced Filter
0) Exit
EOF

read -rp "> " c

case $c in
1) check_dependencies;;
2) restart_network;;
3) select_interface;;
4) scan_networks;;
5) scan_and_save;;
6) live_scan;;
7) filter_signal;;
8) filter_security;;
9) advanced_filter;;
0) exit 0;;
*) warn "Invalid";;
esac

read -rp "Enter to continue..." _
done
}

############################################
# MAIN
############################################
main(){
    require_root
    menu
}

main "$@"

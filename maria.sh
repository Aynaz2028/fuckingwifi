#!/usr/bin/env bash

# Ultimate WiFi Toolkit (Compatible Version - No Monitor Mode)

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
        if ! command -v "$cmd" &>/dev/null; then
            warn "$cmd not found"
        fi
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
list_interfaces(){
    ip -o link show | awk -F': ' '{print $2}' | grep -v lo
}

select_interface(){
    mapfile -t ifs < <(list_interfaces)

    echo "Available interfaces:"
    for i in "${!ifs[@]}"; do
        echo "[$i] ${ifs[$i]}"
    done

    read -rp "Select: " idx
    INTERFACE="${ifs[$idx]:-}"

    [[ -z "$INTERFACE" ]] && { warn "Invalid"; return; }

    log "Using $INTERFACE"
}

ensure_interface_up(){
    [[ -n "$INTERFACE" ]] && ip link set "$INTERFACE" up 2>/dev/null || true
}

############################################
# SCANNING (NO MONITOR MODE)
############################################
scan_networks(){
    [[ -z "$INTERFACE" ]] && { warn "Select interface first"; return; }

    ensure_interface_up

    log "Scanning networks..."

    if command -v nmcli &>/dev/null; then
        nmcli -f IN-USE,SSID,BSSID,CHAN,SIGNAL,SECURITY device wifi list
    elif command -v iw &>/dev/null; then
        iw dev "$INTERFACE" scan | grep -E 'BSS|SSID|signal'
    else
        warn "No scanning tool available"
    fi
}

scan_and_save(){
    [[ -z "$INTERFACE" ]] && { warn "Select interface"; return; }

    OUT="$SESSION_DIR/scan_$(date +%s).txt"

    nmcli -f SSID,BSSID,CHAN,SIGNAL,SECURITY device wifi list > "$OUT"

    log "Saved to $OUT"
}

############################################
# MENU
############################################
menu(){
while true; do
clear
cat <<EOF
==== FINAL WIFI TOOLKIT ====
1) Check Dependencies
2) Fix Network (Install/Restart)
3) Select Interface
4) Scan Networks
5) Scan & Save
0) Exit
EOF

read -rp "> " c

case $c in
1) check_dependencies;;
2) restart_network;;
3) select_interface;;
4) scan_networks;;
5) scan_and_save;;
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

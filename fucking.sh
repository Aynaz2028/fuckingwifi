#!/usr/bin/env bash

# ULTIMATE WiFi Auditing Toolkit
# Modular • TUI-ready • JSON/DB ready • Extendable

set -euo pipefail
IFS=$'\n\t'

############################################
# CONFIG
############################################
BASE_DIR="$PWD"
SESSION_DIR="$BASE_DIR/sessions"
DB_FILE="$SESSION_DIR/networks.db"
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
# GLOBAL STATE
############################################
INTERFACE=""
MONITOR_INTERFACE=""
CURRENT_SCAN=""

############################################
# LOGGING
############################################
log(){ echo -e "${GREEN}[+]${RESET} $*"; echo "[$(date)] $*" >> "$LOG_FILE"; }
warn(){ echo -e "${YELLOW}[!]${RESET} $*"; echo "[$(date)] WARN: $*" >> "$LOG_FILE"; }
error(){ echo -e "${RED}[-]${RESET} $*"; echo "[$(date)] ERR: $*" >> "$LOG_FILE"; }

############################################
# ROOT
############################################
require_root(){ [[ $EUID -ne 0 ]] && { error "Run as root"; exit 1; }; }

############################################
# DEPENDENCIES
############################################
DEPENDENCIES=(airmon-ng airodump-ng iw ip awk grep column sqlite3 jq fzf)

check_dependencies(){
    local fail=0
    for d in "${DEPENDENCIES[@]}"; do
        command -v "$d" &>/dev/null || { warn "Missing $d"; fail=1; }
    done
    [[ $fail -eq 1 ]] && warn "Some features may not work"
}

############################################
# DATABASE INIT
############################################
init_db(){
sqlite3 "$DB_FILE" "
CREATE TABLE IF NOT EXISTS networks (
    id INTEGER PRIMARY KEY,
    bssid TEXT,
    channel TEXT,
    encryption TEXT,
    essid TEXT,
    timestamp TEXT
);"
}

############################################
# NETWORK CONTROL
############################################
restart_network(){
    log "Checking network control..."

    # Try NetworkManager via nmcli (works even without systemctl)
    if command -v nmcli &>/dev/null; then
        log "Using nmcli to reconnect network"
        nmcli networking off || true
        sleep 1
        nmcli networking on || true
        return
    fi

    # Try systemd services
    if command -v systemctl &>/dev/null; then
        if systemctl list-unit-files | grep -q '^NetworkManager\\.service'; then
            systemctl restart NetworkManager && return
        fi
        if systemctl list-unit-files | grep -q '^systemd-networkd\\.service'; then
            systemctl restart systemd-networkd && return
        fi
    fi

    # Try legacy service command
    if command -v service &>/dev/null; then
        if service --status-all 2>/dev/null | grep -q "networking"; then
            service networking restart && return
        fi
        if service --status-all 2>/dev/null | grep -q "NetworkManager"; then
            service NetworkManager restart && return
        fi
    fi

    # Fallback: reset interface directly
    if command -v ip &>/dev/null && [[ -n "${INTERFACE:-}" ]]; then
        log "Resetting interface $INTERFACE"
        ip link set "$INTERFACE" down || true
        sleep 1
        ip link set "$INTERFACE" up || true
        return
    fi

    warn "No automatic network control available. Manual reconnect may be required."
}

############################################
# INTERFACE
############################################
list_interfaces(){ ip -o link show | awk -F': ' '{print $2}' | grep -v lo; }

select_interface(){
    mapfile -t ifs < <(list_interfaces)
    for i in "${!ifs[@]}"; do echo "[$i] ${ifs[$i]}"; done
    read -rp "> " idx
    INTERFACE="${ifs[$idx]:-}"
    [[ -z "$INTERFACE" ]] && { warn "Invalid"; return; }
    log "Using $INTERFACE"
}

############################################
# MONITOR MODE
############################################
enable_monitor(){
    [[ -z "$INTERFACE" ]] && { warn "Select interface"; return; }
    airmon-ng start "$INTERFACE" >/dev/null
    MONITOR_INTERFACE="${INTERFACE}mon"
}

disable_monitor(){
    [[ -n "$MONITOR_INTERFACE" ]] && airmon-ng stop "$MONITOR_INTERFACE" >/dev/null || true
}

############################################
# SCANNING
############################################
scan(){
    [[ -z "$MONITOR_INTERFACE" ]] && { warn "Enable monitor"; return; }
    CURRENT_SCAN="$SESSION_DIR/scan_$(date +%s)"
    airodump-ng -w "$CURRENT_SCAN" "$MONITOR_INTERFACE"
}

############################################
# PARSE → DB
############################################
parse_to_db(){
    FILE=$(ls -t "$SESSION_DIR"/*.csv 2>/dev/null | head -n1)
    [[ -z "$FILE" ]] && { warn "No scan"; return; }

    awk -F',' 'NR>2 && $1!="" {
        printf "%s|%s|%s|%s\n", $1,$4,$6,$14
    }' "$FILE" | while IFS='|' read -r bssid ch enc essid; do
        sqlite3 "$DB_FILE" "INSERT INTO networks (bssid,channel,encryption,essid,timestamp)
        VALUES ('$bssid','$ch','$enc','$essid','$(date)');"
    done

    log "Saved to DB"
}

############################################
# VIEW DB (TABLE)
############################################
view_db(){
    sqlite3 -header -column "$DB_FILE" "SELECT * FROM networks ORDER BY id DESC LIMIT 20;"
}

############################################
# FUZZY SEARCH
############################################
search_network(){
    sqlite3 "$DB_FILE" "SELECT bssid||' | '||essid FROM networks" | fzf
}

############################################
# ANALYSIS ENGINE
############################################
analyze(){
    echo "\nAnalysis Report:";
    sqlite3 "$DB_FILE" "SELECT essid FROM networks WHERE encryption LIKE '%WEP%';" | sed 's/^/Weak (WEP): /'
    sqlite3 "$DB_FILE" "SELECT essid FROM networks WHERE encryption LIKE '%OPN%';" | sed 's/^/Open: /'
}

############################################
# LIVE DASHBOARD (basic)
############################################
dashboard(){
while true; do
clear
printf "==== LIVE DASHBOARD ====\n"
sqlite3 "$DB_FILE" "SELECT essid,channel,encryption FROM networks ORDER BY id DESC LIMIT 10;"
sleep 2
done
}

############################################
# MENU
############################################
menu(){
while true; do
clear
cat <<EOF
==== ULTIMATE WiFi TOOLKIT ====
1) Check Dependencies
2) Init Database
3) Select Interface
4) Enable Monitor Mode
5) Scan Networks
6) Save Scan to DB
7) View Database
8) Search Network (fzf)
9) Analyze Networks
10) Live Dashboard
11) Disable Monitor
0) Exit
EOF
read -rp "> " c
case $c in
1) check_dependencies;;
2) init_db;;
3) select_interface;;
4) enable_monitor;;
5) scan;;
6) parse_to_db;;
7) view_db;;
8) search_network;;
9) analyze;;
10) dashboard;;
11) disable_monitor;;
0) exit 0;;
*) warn "Invalid";;
esac
read -rp "Enter to continue..." _
done
}

############################################
# CLEANUP
############################################
cleanup(){ disable_monitor; restart_network; }
trap cleanup EXIT

############################################
# MAIN
############################################
main(){ require_root; check_dependencies; init_db; menu; }
main "$@"

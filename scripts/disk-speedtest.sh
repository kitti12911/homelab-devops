#!/usr/bin/env bash
#
# disk-speedtest.sh - identify disks with lsblk, then benchmark one with hdparm + dd.
#
# Usage:
#   ./disk-speedtest.sh                 # auto-detect: first nvme, else first non-removable disk
#   ./disk-speedtest.sh /dev/nvme0n1    # explicit device
#   ./disk-speedtest.sh /dev/sda /mnt/data   # explicit device + where to put the dd test file
#
# Safe on the drive the OS is running from:
#   - hdparm only does read-only timings (-T, -t)
#   - dd writes a regular FILE, never the raw device
#
set -euo pipefail

DEV="${1:-}"
TESTDIR="${2:-}"
SIZE_MB=4096          # dd sequential test size
TESTFILE_NAME=".disk-speedtest.tmp"

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root: sudo $0 $*" >&2
    exit 1
fi

# --- install deps ------------------------------------------------------------
echo "=== installing hdparm ==="
if ! command -v hdparm >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y hdparm
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y hdparm
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm hdparm
    else
        echo "no known package manager; install hdparm manually" >&2
        exit 1
    fi
else
    echo "hdparm already installed"
fi
echo

# --- identify drives ---------------------------------------------------------
echo "=== lsblk: all block devices ==="
lsblk -o NAME,SIZE,TYPE,TRAN,ROTA,MODEL,FSTYPE,MOUNTPOINT
echo

# auto-detect device if not given
if [ -z "$DEV" ]; then
    DEV=$(lsblk -dn -o NAME,TYPE,TRAN | awk '$2=="disk" && $3=="nvme" {print "/dev/"$1; exit}')
    if [ -z "$DEV" ]; then
        DEV=$(lsblk -dn -o NAME,TYPE,RM | awk '$2=="disk" && $3=="0" {print "/dev/"$1; exit}')
    fi
    [ -n "$DEV" ] || { echo "could not auto-detect a disk; pass one as \$1" >&2; exit 1; }
    echo "auto-detected device: $DEV"
fi

[ -b "$DEV" ] || { echo "$DEV is not a block device" >&2; exit 1; }

echo "=== target device: $DEV ==="
lsblk -o NAME,SIZE,TYPE,TRAN,ROTA,MODEL,FSTYPE,MOUNTPOINT "$DEV"
echo
echo "--- rotational (0 = SSD/flash, 1 = spinning) ---"
cat "/sys/block/$(basename "$DEV")/queue/rotational" 2>/dev/null || echo "n/a"
echo
if command -v lspci >/dev/null 2>&1 && [[ "$DEV" == *nvme* ]]; then
    echo "--- PCIe link (LnkCap = drive capability, LnkSta = actual negotiated) ---"
    SLOT=$(lspci | grep -i "non-volatile" | head -1 | cut -d' ' -f1)
    [ -n "$SLOT" ] && lspci -vv -s "$SLOT" 2>/dev/null | grep -E "LnkCap:|LnkSta:" || echo "n/a"
    echo
fi

# --- pick where the dd test file goes ----------------------------------------
if [ -z "$TESTDIR" ]; then
    TESTDIR=$(lsblk -no MOUNTPOINT "$DEV" | grep -v '^$' | grep -v '/boot' | head -1)
    [ -n "$TESTDIR" ] || { echo "no mountpoint found on $DEV; pass a test dir as \$2" >&2; exit 1; }
fi
TESTFILE="$TESTDIR/$TESTFILE_NAME"

AVAIL_MB=$(df -Pm "$TESTDIR" | awk 'NR==2 {print $4}')
if [ "$AVAIL_MB" -lt $((SIZE_MB + 1024)) ]; then
    echo "not enough free space in $TESTDIR (${AVAIL_MB}MB avail, need $((SIZE_MB + 1024))MB)" >&2
    exit 1
fi
echo "dd test file: $TESTFILE (${SIZE_MB}MB, ${AVAIL_MB}MB free)"
echo

cleanup() { rm -f "$TESTFILE"; }
trap cleanup EXIT

# --- hdparm: read-only timings on the raw device -----------------------------
echo "=== hdparm: O_DIRECT reads (bypasses page cache - the real number) ==="
hdparm -Tt --direct "$DEV"
echo
echo "=== hdparm: buffered reads (-T here measures RAM, not the disk) ==="
hdparm -Tt "$DEV"
echo

# --- dd: sequential write/read through the filesystem ------------------------
echo "=== dd WRITE ${SIZE_MB}MB, bs=1M, O_DIRECT ==="
dd if=/dev/zero of="$TESTFILE" bs=1M count="$SIZE_MB" oflag=direct 2>&1 | tail -1
echo

echo "=== dd WRITE ${SIZE_MB}MB, bs=1M, buffered + fdatasync ==="
dd if=/dev/zero of="$TESTFILE" bs=1M count="$SIZE_MB" conv=fdatasync 2>&1 | tail -1
echo

echo "=== dd READ ${SIZE_MB}MB, bs=1M, O_DIRECT ==="
sync; echo 3 > /proc/sys/vm/drop_caches
dd if="$TESTFILE" of=/dev/null bs=1M iflag=direct 2>&1 | tail -1
echo

echo "=== dd READ ${SIZE_MB}MB, bs=1M, buffered (cold cache) ==="
sync; echo 3 > /proc/sys/vm/drop_caches
dd if="$TESTFILE" of=/dev/null bs=1M 2>&1 | tail -1
echo

echo "=== dd WRITE 256MB, bs=4k, O_DIRECT (small-block latency floor) ==="
dd if=/dev/zero of="$TESTFILE" bs=4k count=65536 oflag=direct 2>&1 | tail -1
echo

echo "=== done, test file removed ==="

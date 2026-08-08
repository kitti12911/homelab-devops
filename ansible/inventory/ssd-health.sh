#!/usr/bin/env bash
# NVMe health + speed check.
#
#   sudo ./ssd-health.sh                 auto-detect the drive, read-only
#   sudo ./ssd-health.sh /dev/nvme0n1    name it explicitly
#   sudo ./ssd-health.sh --write         also test WRITE speed (DESTROYS data, asks first)
#
# Uses only nvme-cli / smartmontools / dd — nothing is installed, so it works offline.

set -uo pipefail

DEV=""
WRITE=0
for a in "$@"; do
    case "$a" in
        --write) WRITE=1 ;;
        -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
        *) DEV="$a" ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }

# --- 1. is a drive attached? --------------------------------------------------
echo "== 1. device"
if [ -z "$DEV" ]; then
    DEV=$(lsblk -dpno NAME,TRAN | awk '$2=="nvme"{print $1; exit}')
fi
if [ -z "$DEV" ] || [ ! -b "$DEV" ]; then
    echo "[fail]  no NVMe found. Check it is seated and the Pi was power-cycled after fitting it." >&2
    lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN >&2
    exit 1
fi

MODEL=$(lsblk -dno MODEL "$DEV" | xargs)
SERIAL=$(lsblk -dno SERIAL "$DEV" | xargs)
SIZE=$(lsblk -dno SIZE "$DEV" | xargs)
echo "[ok]    $DEV  |  $MODEL  |  SN $SERIAL  |  $SIZE"
LINK=$(cat /sys/class/nvme/nvme0/device/current_link_speed 2>/dev/null || true)
[ -n "$LINK" ] && echo "        PCIe link: $LINK"
echo

# --- 2. SMART -----------------------------------------------------------------
echo "== 2. SMART"
if ! command -v nvme >/dev/null 2>&1; then
    echo "[fail]  nvme-cli not installed (apt install nvme-cli). Trying smartctl instead." >&2
    command -v smartctl >/dev/null 2>&1 && smartctl -a "$DEV" | sed 's/^/   /'
    exit 1
fi
SMART=$(nvme smart-log "$DEV")

# tolerate both "data_units_written : 1" and "Data Units Written : 1 (0.5 TB)"
num() {
    printf '%s\n' "$SMART" | awk -F: -v k="$1" '
        { key=$1; sub(/[ \t]+$/,"",key); key=tolower(key); gsub(/[ \t]+/,"_",key)
          if (key!=k) next
          v=$2; sub(/^[ \t]+/,"",v)
          if (match(v,/^[0-9,]+/)) { v=substr(v,1,RLENGTH); gsub(/,/,"",v); print v+0; exit } }' | head -1
}

PCT=$(num percentage_used)
SPARE=$(num available_spare)
THRESH=$(num available_spare_threshold)
DUW=$(num data_units_written)
POH=$(num power_on_hours)
PCY=$(num power_cycles)
USHUT=$(num unsafe_shutdowns)
MERR=$(num media_errors)
CWARN=$(num critical_warning)
ERRLOG=$(num num_err_log_entries)
TEMP=$(num temperature)
TBW=$(awk -v d="${DUW:-0}" 'BEGIN{printf "%.2f", d*512000/1e12}')

printf '   %-22s %s%%\n' "percentage_used"  "$PCT"
printf '   %-22s %s%% (fail below %s%%)\n' "available_spare" "$SPARE" "$THRESH"
printf '   %-22s %s TB\n' "written (TBW)"   "$TBW"
printf '   %-22s %s\n'    "power_on_hours"  "$POH"
printf '   %-22s %s\n'    "power_cycles"    "$PCY"
printf '   %-22s %s\n'    "unsafe_shutdowns" "$USHUT"
printf '   %-22s %s\n'    "media_errors"    "$MERR"
printf '   %-22s %s\n'    "critical_warning" "$CWARN"
printf '   %-22s %s\n'    "error log entries" "$ERRLOG"
printf '   %-22s %s C\n'  "temperature"     "$TEMP"
echo

# --- 3. health percentage -----------------------------------------------------
echo "== 3. health"
HEALTH=$(( 100 - ${PCT:-0} ))
echo "   life remaining      ${HEALTH}%   (100 - percentage_used)"

# NVMe never publishes its rated TBW; back-calculate it from the wear estimate
if [ "${PCT:-0}" -gt 0 ] && [ "${DUW:-0}" -gt 0 ]; then
    awk -v tbw="$TBW" -v pct="$PCT" -v poh="$POH" 'BEGIN{
        total=tbw/(pct/100); left=total-tbw
        printf "   implied endurance   ~%.0f TB rated, ~%.0f TB left\n", total, left
        if (poh>0) { rate=tbw/(poh/8760)
            printf "   at this write rate  %.1f TB/year -> ~%.0f years left\n", rate, left/rate }
    }'
else
    echo "   implied endurance   n/a (drive reports 0% used or no write counter)"
fi

VERDICT="GOOD"
WHY="no errors, spare full, low wear"
if [ "${MERR:-0}" -gt 0 ] || [ "${CWARN:-0}" -ne 0 ]; then
    VERDICT="BAD"; WHY="media errors or a critical warning present"
elif [ "${SPARE:-100}" -le "${THRESH:-10}" ]; then
    VERDICT="BAD"; WHY="available spare at or below the failure threshold"
elif [ "${PCT:-0}" -gt 80 ]; then
    VERDICT="WORN"; WHY="over 80% of rated life used"
elif [ "${PCT:-0}" -gt 20 ]; then
    VERDICT="OK"; WHY="noticeable wear but healthy"
fi
echo "   VERDICT: $VERDICT  ($WHY)"
echo

# --- 4. speed -----------------------------------------------------------------
echo "== 4. speed"
echo "[start] sequential read, 1 GiB"
R=$(LC_ALL=C dd if="$DEV" of=/dev/null bs=1M count=1024 iflag=direct 2>&1 | tail -1 | sed 's/.*, //')
echo "[ok]    read : ${R:-unknown}"

if [ "$WRITE" -eq 1 ]; then
    MOUNTED=$(lsblk -nro MOUNTPOINT "$DEV" | grep -c . || true)
    if [ "$MOUNTED" -gt 0 ]; then
        echo "[fail]  $DEV has mounted partitions — refusing to write. Unmount first." >&2
    else
        echo "!!      the write test OVERWRITES the first 1 GiB of $DEV (SN $SERIAL)"
        printf '        type ERASE to continue: '
        read -r ans
        if [ "$ans" = "ERASE" ]; then
            W=$(LC_ALL=C dd if=/dev/zero of="$DEV" bs=1M count=1024 oflag=direct 2>&1 | tail -1 | sed 's/.*, //')
            echo "[ok]    write: ${W:-unknown}"
        else
            echo "[skip]  write test cancelled"
        fi
    fi
else
    echo "        (add --write to test write speed — it overwrites data)"
fi

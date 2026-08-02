#!/usr/bin/env bash
set -euo pipefail

# Weekly mirror of selected folders from the active disk to the backup disk —
# runs ON the NAS host, normally through nas-backup.timer rather than by hand.
#
# Additive by design: no --delete anywhere. A file removed from the active share
# stays on the backup disk, so an accidental delete over SMB is always
# recoverable. The cost is drift — a rename leaves both the old and the new copy
# behind, and the backup only ever grows. `nas-backup status` reports the size
# gap so that drift stays visible instead of quietly eating the disk.
#
# The backup disk is normally noauto+ro (see nas_cleanup in setup-nas-shares.yml)
# so it stays spun down between runs. This script mounts it read-write for the
# duration and puts it back exactly as it found it, which is what keeps a weekly
# job from turning into a permanently spinning second disk.
#
# Deployed to /usr/local/sbin/nas-backup, with its configuration, by:
#   ansible/playbooks/infrastructure/setup-nas-shares.yml
#
# Usage: sudo nas-backup [run|dry-run|status]
#   run      — sync every configured folder (default)
#   dry-run  — report exactly what run would transfer, and change nothing
#   status   — show configuration, mount state, sizes and last run result
#
# Environment:
#   NAS_BACKUP_CONF=<path>   read configuration from somewhere other than
#                            /etc/nas-backup.conf

CONF="${NAS_BACKUP_CONF:-/etc/nas-backup.conf}"
LOCK=/run/nas-backup.lock
ACTION="${1:-run}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

die() {
    red "error: $*" >&2
    exit 1
}

# --- Preconditions ---------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root: sudo $0 $*"
[ -r "$CONF" ] || die "no configuration at $CONF — run setup-nas-shares.yml first"

command -v rsync >/dev/null || die "rsync not found — install it (apt install rsync)"

# shellcheck source=/dev/null
. "$CONF"

: "${NAS_BACKUP_SRC:?not set in $CONF}"
: "${NAS_BACKUP_DST:?not set in $CONF}"
: "${NAS_BACKUP_GROUP:=nasusers}"
: "${NAS_BACKUP_MIN_FREE_GB:=10}"
PATHS=("${NAS_BACKUP_PATHS[@]:-}")
EXCLUDES=("${NAS_BACKUP_EXCLUDES[@]:-}")

[ "${#PATHS[@]}" -gt 0 ] && [ -n "${PATHS[0]}" ] ||
    die "NAS_BACKUP_PATHS is empty in $CONF — nothing is configured to back up"

# --- Mount handling --------------------------------------------------------
# Restoring the destination to however it was found is the whole reason these
# two flags exist: an interrupted run must not leave the backup disk mounted
# read-write and awake until the next reboot.
mounted_by_us=0
remounted_rw=0

restore_dest() {
    if [ "$mounted_by_us" = 1 ]; then
        sync
        if umount "$NAS_BACKUP_DST" 2>/dev/null; then
            echo "unmounted $NAS_BACKUP_DST — disk will spin down on its idle timer"
        else
            yellow "warning: could not unmount $NAS_BACKUP_DST (still busy?)"
        fi
    elif [ "$remounted_rw" = 1 ]; then
        sync
        mount -o remount,ro "$NAS_BACKUP_DST" 2>/dev/null ||
            yellow "warning: could not restore $NAS_BACKUP_DST to read-only"
    fi
}

is_mounted() { mountpoint -q "$1"; }
is_readonly() { findmnt -no OPTIONS "$1" 2>/dev/null | tr ',' '\n' | grep -qx ro; }

# Mounting by mount point alone makes mount(8) read the fstab entry, so the
# UUID and fstype never have to be duplicated here. Options given on the command
# line are appended after the fstab ones, which is what lets rw override the ro
# that the backup role writes.
open_dest() {
    if ! is_mounted "$NAS_BACKUP_DST"; then
        mount -o rw "$NAS_BACKUP_DST" ||
            die "cannot mount $NAS_BACKUP_DST — is the backup disk plugged in? (lsblk -f)"
        mounted_by_us=1
        is_mounted "$NAS_BACKUP_DST" || die "$NAS_BACKUP_DST still not mounted after mount(8) reported success"
        echo "mounted $NAS_BACKUP_DST read-write for this run"
    elif is_readonly "$NAS_BACKUP_DST"; then
        mount -o remount,rw "$NAS_BACKUP_DST" ||
            die "$NAS_BACKUP_DST is mounted read-only and cannot be remounted read-write"
        remounted_rw=1
        echo "remounted $NAS_BACKUP_DST read-write for this run"
    fi
}

# A source that is not a mount point means the active disk failed to mount and
# $NAS_BACKUP_SRC is the bare directory on the OS SSD. Syncing from it would
# quietly mirror an empty tree; with no --delete that destroys nothing, but it
# reports success for a backup that copied nothing at all.
assert_source() {
    is_mounted "$NAS_BACKUP_SRC" ||
        die "$NAS_BACKUP_SRC is not a mount point — the active disk is not mounted, refusing to run"
}

free_gb() { df -BG --output=avail "$1" 2>/dev/null | tail -1 | tr -dc '0-9'; }

rsync_args() {
    # -a alone is right for ext4 -> ext4 on one host: permissions, times, symlinks
    # and the nasusers group all carry over as they are. No -z, because compressing
    # a local disk-to-disk copy only burns the two cores this box has, and no
    # --delete, because this backup is deliberately additive.
    printf '%s\n' -a --stats --human-readable
    local ex
    for ex in "${EXCLUDES[@]}"; do
        [ -n "$ex" ] && printf '%s\n' "--exclude=$ex"
    done
}

# --- Actions ---------------------------------------------------------------
case "$ACTION" in
    run | dry-run)
        dry=0
        [ "$ACTION" = dry-run ] && dry=1

        # Two runs overlapping would have them competing for the same spinning
        # disk, and the second would unmount the destination out from under the
        # first on exit.
        exec 9>"$LOCK"
        flock -n 9 || die "another nas-backup run is already in progress"

        assert_source
        trap restore_dest EXIT
        open_dest

        avail=$(free_gb "$NAS_BACKUP_DST")
        [ "${avail:-0}" -ge "$NAS_BACKUP_MIN_FREE_GB" ] ||
            die "only ${avail}GB free on $NAS_BACKUP_DST, below the ${NAS_BACKUP_MIN_FREE_GB}GB floor — this backup never deletes, so free space has to be reclaimed by hand"

        mapfile -t args < <(rsync_args)
        [ "$dry" = 1 ] && args+=(--dry-run)

        started=$(date +%s)
        failed=0
        for rel in "${PATHS[@]}"; do
            [ -n "$rel" ] || continue
            echo
            echo "=== $rel ==="

            if [ ! -d "$NAS_BACKUP_SRC/$rel" ]; then
                red "missing on the active disk: $NAS_BACKUP_SRC/$rel — skipped"
                failed=1
                continue
            fi

            if [ "$dry" = 0 ]; then
                # rsync's trailing-slash form maps contents onto contents and
                # never touches the attributes of the destination's top directory,
                # so it is created and grouped here instead. 2775 matches the
                # directory mask the shares are exported with.
                mkdir -p "$NAS_BACKUP_DST/$rel"
                chgrp "$NAS_BACKUP_GROUP" "$NAS_BACKUP_DST/$rel" 2>/dev/null || true
                chmod 2775 "$NAS_BACKUP_DST/$rel" 2>/dev/null || true
            fi

            if rsync "${args[@]}" "$NAS_BACKUP_SRC/$rel/" "$NAS_BACKUP_DST/$rel/"; then
                green "$rel: ok"
            else
                rc=$?
                red "$rel: rsync exited $rc"
                failed=1
            fi
        done

        echo
        echo "elapsed: $(($(date +%s) - started))s"
        echo "free on $NAS_BACKUP_DST: $(free_gb "$NAS_BACKUP_DST")GB"

        if [ "$failed" = 1 ]; then
            red "one or more folders failed — see above"
            exit 1
        fi
        if [ "$dry" = 1 ]; then
            green "dry run complete — nothing was written"
        else
            green "backup complete"
        fi
        ;;

    status)
        echo "config:  $CONF"
        echo "source:  $NAS_BACKUP_SRC  ($(is_mounted "$NAS_BACKUP_SRC" && echo mounted || echo "NOT MOUNTED"))"
        echo "dest:    $NAS_BACKUP_DST  ($(is_mounted "$NAS_BACKUP_DST" &&
            { is_readonly "$NAS_BACKUP_DST" && echo "mounted ro" || echo "mounted rw"; } ||
            echo "not mounted — normal between runs"))"
        echo "mode:    additive (no --delete; deleted files are kept on the backup disk)"
        echo
        printf '    %-24s %10s %10s\n' "FOLDER" "ACTIVE" "BACKUP"
        for rel in "${PATHS[@]}"; do
            [ -n "$rel" ] || continue
            s="-"
            d="-"
            [ -d "$NAS_BACKUP_SRC/$rel" ] && s=$(du -sh "$NAS_BACKUP_SRC/$rel" 2>/dev/null | cut -f1)
            [ -d "$NAS_BACKUP_DST/$rel" ] && d=$(du -sh "$NAS_BACKUP_DST/$rel" 2>/dev/null | cut -f1)
            printf '    %-24s %10s %10s\n' "$rel" "$s" "$d"
        done
        echo
        echo "A backup column larger than active is expected: files deleted on the"
        echo "share are retained here. Reclaim space by deleting from the backup disk."
        echo
        systemctl list-timers nas-backup.timer --no-pager 2>/dev/null || true
        echo
        systemctl status nas-backup.service --no-pager --lines=0 2>/dev/null || true
        ;;

    *)
        die "unknown action '$ACTION' — expected run, dry-run or status"
        ;;
esac

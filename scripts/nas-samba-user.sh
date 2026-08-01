#!/usr/bin/env bash
set -euo pipefail

# Manage the Samba account used to reach the NAS shares — run ON the NAS host.
#
# Samba keeps its own password database (/var/lib/samba/private/passdb.tdb),
# entirely separate from Unix/PAM. An SSH key that logs you in gives you nothing
# over SMB: the account has to exist in both places, and the Samba half has to be
# given a password explicitly. That is the whole reason this script exists.
#
# Deployed to /usr/local/sbin/nas-samba-user by:
#   ansible/playbooks/infrastructure/setup-nas-shares.yml
#
# Usage: sudo nas-samba-user [add|reset|list|delete] [username]
#   add     — create the account if missing, set its password, enable it (default)
#   reset   — change the password of an existing account
#   list    — show every Samba account and its flags
#   delete  — remove the Samba account (leaves the Unix account alone)
#
#   username defaults to the invoking user ($SUDO_USER).
#
# Examples:
#   sudo nas-samba-user                 # add/enable the current user
#   sudo nas-samba-user add media       # a second, share-only account
#   sudo nas-samba-user reset kitti
#   sudo nas-samba-user list
#
# Environment:
#   NAS_CREATE_LOGIN=1   when the Unix account has to be created, make it a normal
#                        login user with a home directory instead of the default
#                        share-only account (no home, /usr/sbin/nologin)

ACTION="${1:-add}"
SMB_USER="${2:-${SUDO_USER:-}}"
CREATE_LOGIN="${NAS_CREATE_LOGIN:-0}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }

die() {
    red "error: $*" >&2
    exit 1
}

# --- Preconditions ---------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root: sudo $0 $*"

for tool in smbpasswd pdbedit; do
    command -v "$tool" >/dev/null ||
        die "$tool not found — install samba first (apt install samba)"
done

if [ -z "$SMB_USER" ]; then
    # Reached when run as root directly rather than through sudo, so $SUDO_USER
    # is unset and there is nothing sensible to guess.
    read -r -p "Samba username: " SMB_USER
    [ -n "$SMB_USER" ] || die "no username given"
fi

samba_user_exists() { pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$SMB_USER"; }
unix_user_exists() { id -u "$SMB_USER" >/dev/null 2>&1; }

# The shares are gated on `valid users = @<group>`, so the group is read back out
# of the live config rather than assumed. That keeps this script correct if the
# playbook is ever run with a different nas_share_group.
resolve_share_group() {
    local from_conf
    from_conf=$(testparm -s 2>/dev/null |
        sed -n 's/^[[:space:]]*valid users[[:space:]]*=[[:space:]]*@\(.*\)$/\1/p' |
        head -1 | tr -d ' ')
    printf '%s' "${from_conf:-${NAS_SHARE_GROUP:-nasusers}}"
}

SHARE_GROUP="$(resolve_share_group)"

# The playbook writes `valid users = @<group>` into every share. An account outside
# that group authenticates and is then refused on every share, which looks exactly
# like a wrong password from the client side.
warn_if_not_in_shares() {
    local allowed
    allowed=$(testparm -s 2>/dev/null | awk -F'=' '/valid users/ {print $2}' | tr -d ' @' | tr '\n' ' ')
    [ -n "$allowed" ] || return 0
    # Membership already satisfies a @group entry, so check the group first.
    id -nG "$SMB_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$SHARE_GROUP" && return 0
    case " $allowed " in
        *" $SMB_USER "*) ;;
        *)
            yellow "warning: '$SMB_USER' cannot reach any share."
            yellow "         Shares allow: $allowed"
            yellow "         Add the account to the share group:"
            yellow "             sudo usermod -aG $SHARE_GROUP $SMB_USER"
            yellow "         or re-run setup-nas-shares.yml, or this account will be"
            yellow "         refused on every share despite a correct password."
            ;;
    esac
}

account_flags() {
    pdbedit -L -v "${1:-$SMB_USER}" 2>/dev/null |
        sed -n 's/.*Account Flags:[[:space:]]*\[\(.*\)\].*/\1/p' | tr -d ' '
}

report() {
    echo
    green "Samba account '$SMB_USER' is ready."
    printf '    %-14s %s\n' "flags:" "$(account_flags)"
    printf '    %-14s %s\n' "groups:" "$(id -nG "$SMB_USER" 2>/dev/null)"
    warn_if_not_in_shares
    echo
    echo "Connect from macOS: Finder -> Cmd+K -> smb://$(hostname -I | awk '{print $1}')"
    echo "Click 'Connect As...' and choose Registered User, not Guest."
    echo
    echo "Shares currently exported:"
    testparm -s 2>/dev/null | grep '^\[' | grep -v global | tr -d '[]' | sed 's/^/    /'
}

# --- Actions ---------------------------------------------------------------
case "$ACTION" in
    add)
        if ! unix_user_exists; then
            if [ "$CREATE_LOGIN" = "1" ]; then
                yellow "Unix account '$SMB_USER' missing — creating with home and shell."
                useradd --create-home --shell /bin/bash "$SMB_USER"
            else
                # Share-only by default: a NAS account has no reason to be able to
                # log in, and no reason to own a home directory.
                yellow "Unix account '$SMB_USER' missing — creating share-only account."
                useradd --no-create-home --shell /usr/sbin/nologin "$SMB_USER"
            fi
            # Locks the Unix password only. Samba authenticates against its own
            # database, so this does not affect SMB logins.
            passwd --lock "$SMB_USER" >/dev/null
        fi

        # The shares are gated on `valid users = @<group>`, so membership is what
        # actually grants access - without this a new account authenticates and is
        # then refused everywhere.
        if ! getent group "$SHARE_GROUP" >/dev/null; then
            yellow "Share group '$SHARE_GROUP' missing — creating it."
            groupadd "$SHARE_GROUP"
        fi
        if id -nG "$SMB_USER" | tr ' ' '\n' | grep -qx "$SHARE_GROUP"; then
            echo "Already in group '$SHARE_GROUP'."
        else
            usermod -aG "$SHARE_GROUP" "$SMB_USER"
            green "Added '$SMB_USER' to group '$SHARE_GROUP'."
        fi

        if samba_user_exists; then
            yellow "Samba account '$SMB_USER' already exists — setting a new password."
            smbpasswd "$SMB_USER"
        else
            echo "Creating Samba account '$SMB_USER'. Choose its SMB password:"
            echo "(this is independent of the Unix password and of your SSH key)"
            smbpasswd -a "$SMB_USER"
        fi

        # An account can exist but be flagged disabled [D], which rejects logins
        # without ever saying the password was fine.
        smbpasswd -e "$SMB_USER" >/dev/null
        report
        ;;

    reset)
        samba_user_exists || die "no Samba account '$SMB_USER' — run: $0 add $SMB_USER"
        smbpasswd "$SMB_USER"
        smbpasswd -e "$SMB_USER" >/dev/null
        report
        ;;

    list)
        printf '    %-16s %-8s %s\n' "ACCOUNT" "FLAGS" "GROUPS"
        pdbedit -L 2>/dev/null | cut -d: -f1 | sort | while read -r u; do
            printf '    %-16s %-8s %s\n' \
                "$u" "$(account_flags "$u")" "$(id -nG "$u" 2>/dev/null)"
        done
        echo
        echo "Flags:  U=normal account, D=disabled, X=password never expires"
        echo "Access: membership of '$SHARE_GROUP' is what grants share access."
        ;;

    delete)
        samba_user_exists || die "no Samba account '$SMB_USER'"
        read -r -p "Remove Samba account '$SMB_USER'? The Unix account stays. [y/N] " reply
        case "$reply" in
            [yY]*)
                smbpasswd -x "$SMB_USER"
                green "Removed Samba account '$SMB_USER'."
                ;;
            *) echo "Cancelled." ;;
        esac
        ;;

    *)
        die "unknown action '$ACTION' — expected add, reset, list or delete"
        ;;
esac

#!/usr/bin/env bash

# samba-mount-tui.sh — TUI tool to discover and mount Samba shares

set -euo pipefail

LOG_FILE="/var/log/samba-mount.log"
TEMP_CRED=""
MOUNT_POINT=""
FSTAB_BACKUP="/etc/fstab.bak.$(date +%s)"
CREDENTIALS_DIR="/root"

# ========== Utility Functions ==========

log() {
    echo "[$(date)] $1" >> "$LOG_FILE"
}

cleanup_temp_files() {
    [[ -f "$TEMP_CRED" ]] && rm -f "$TEMP_CRED"
}

trap cleanup_temp_files EXIT

check_dependencies() {
    local deps=(dialog smbclient cifs-utils samba-common-bin)

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null; then
            echo "Installing $dep..."
            apt-get update && apt-get install -y "$dep"
        fi
    done
}

# ========== Main Functions ==========

discover_shares() {
    local host="$1"
    smbclient -L "//$host" -N 2>/tmp/smbout || {
        dialog --msgbox "Could not connect to $host.\n$(cat /tmp/smbout)" 10 60
        exit 1
    }

    grep -A9999 "Sharename" /tmp/smbout | awk 'NF && $1 != "Sharename" && $1 != "---" {print $1}' > /tmp/sharelist
    if [[ ! -s /tmp/sharelist ]]; then
        dialog --msgbox "No shares found on host $host." 8 50
        exit 1
    fi
}

prompt_user_input() {
    exec 3>&1

    HOST=$(dialog --inputbox "Enter Samba host or IP address:" 8 50 2>&1 1>&3)
    discover_shares "$HOST"

    SHARE=$(dialog --menu "Select a share to mount from $HOST:" 20 50 10 $(awk '{print $1, $1}' /tmp/sharelist) 2>&1 1>&3)

    DEFAULT_MOUNT="/mnt/$SHARE"
    MOUNT_POINT=$(dialog --inputbox "Enter mount point:" 8 50 "$DEFAULT_MOUNT" 2>&1 1>&3)

    USERNAME=$(dialog --inputbox "Enter username (leave blank for guest):" 8 50 2>&1 1>&3)
    PASSWORD=$(dialog --insecure --passwordbox "Enter password:" 8 50 2>&1 1>&3)
    DOMAIN=$(dialog --inputbox "Enter domain/workgroup (optional):" 8 50 2>&1 1>&3)

    # Optional mount flags
    MOUNT_FLAGS=$(dialog --checklist "Mount options:" 15 60 6 \
        "ro" "Read-only" off \
        "noexec" "No execute permission" off \
        "nosuid" "Ignore SUID" off \
        "uid=$(id -u)" "Set user ID" on \
        "gid=$(id -g)" "Set group ID" on \
        2>&1 1>&3 | tr -d '"')

    AUTO_FSTAB=$(dialog --yesno "Add to /etc/fstab for auto-mount on boot?" 7 50; echo $?)
    SAVE_CREDS=$(dialog --yesno "Save credentials in /root/.smbcredentials_$HOST?" 7 50; echo $?)

    exec 3>&-
}

mount_share() {
    mkdir -p "$MOUNT_POINT"

    local options="vers=3.0"
    [[ -n "$USERNAME" ]] && options+=",username=$USERNAME"
    [[ -n "$DOMAIN" ]] && options+=",domain=$DOMAIN"

    if [[ "$SAVE_CREDS" -eq 0 ]]; then
        CRED_FILE="$CREDENTIALS_DIR/.smbcredentials_$HOST"
        TEMP_CRED="$CRED_FILE"
        echo -e "username=$USERNAME\npassword=$PASSWORD\ndomain=$DOMAIN" > "$CRED_FILE"
        chmod 600 "$CRED_FILE"
        options+=",credentials=$CRED_FILE"
    else
        TEMP_CRED=$(mktemp)
        echo -e "username=$USERNAME\npassword=$PASSWORD\ndomain=$DOMAIN" > "$TEMP_CRED"
        chmod 600 "$TEMP_CRED"
        options+=",credentials=$TEMP_CRED"
    fi

    [[ -n "$MOUNT_FLAGS" ]] && options+=",$(echo "$MOUNT_FLAGS" | tr ' ' ',')"

    dialog --gauge "Mounting //$HOST/$SHARE to $MOUNT_POINT..." 10 60 50 &

    if mount -t cifs "//$HOST/$SHARE" "$MOUNT_POINT" -o "$options"; then
        log "Mounted //$HOST/$SHARE to $MOUNT_POINT"
        dialog --msgbox "Share mounted successfully!" 6 40

        if [[ "$AUTO_FSTAB" -eq 0 ]]; then
            cp /etc/fstab "$FSTAB_BACKUP"
            echo "//$HOST/$SHARE $MOUNT_POINT cifs $options 0 0" >> /etc/fstab
            log "fstab updated for //$HOST/$SHARE"
        fi

        # Optional: show disk usage
        dialog --msgbox "$(df -h "$MOUNT_POINT")" 15 60
    else
        dialog --msgbox "Mount failed.\nSee log at $LOG_FILE" 10 50
        log "Mount failed for //$HOST/$SHARE"
    fi
}

# ========== Optional Enhancements ==========

# Auto-discovery (e.g., via avahi or nmblookup) could be added here.
# Bookmarking profiles for quick remounting would be stored in a config dir.

# ========== Main ==========

if [[ "$EUID" -ne 0 ]]; then
    echo "Please run as root."
    exit 1
fi

check_dependencies
prompt_user_input
mount_share
cleanup_temp_files

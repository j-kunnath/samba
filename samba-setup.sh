#!/bin/sh
#
# samba-share-setup.sh — Interactive Samba share configuration tool using dialog
#
# Description:
#   Menu-driven CLI for Samba share configuration with support for advanced options.
#   Creates, manages, and applies share definitions to smb.conf.
#
# Author: ChatGPT
# License: MIT

### CONFIGURABLE VARIABLES ###
LOGFILE="/var/log/samba-share-setup.log"
SMB_CONF="/etc/samba/smb.conf"
BACKUP_CONF="/etc/samba/smb.conf.bak"
LANGFILE="./lang/en.lang" # i18n support (future extension)

### GLOBAL VARIABLES ###
SHARE_NAME=""
SHARE_PATH=""
COMMENT=""
GUEST_OK="no"
READ_ONLY="yes"
BROWSEABLE="yes"
CREATE_MASK="0755"
DIR_MASK="0755"
VALID_USERS=""
FORCE_USER=""
FORCE_GROUP=""
VFS_OBJECTS=""
SYSTEM_USERS=""
LOCAL_IP=""

### TRAPS ###
trap 'cleanup' INT TERM

cleanup() {
  dialog --clear
  clear
  echo "Interrupted. Exiting..."
  exit 1
}

log() {
  echo "$(date '+%F %T') : $1" >> "$LOGFILE"
}

check_dependencies() {
  for pkg in samba dialog; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
      echo "Installing missing package: $pkg"
      apt-get update && apt-get install -y "$pkg"
    fi
  done

  SYSTEM_USERS=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 { print $1 }')
  LOCAL_IP=$(ip a | awk '/inet / && $2 !~ /127.0.0.1/ { print $2 }' | head -n 1)
}

show_main_menu() {
  dialog --backtitle "Samba Share Setup Tool" --title "Main Menu" \
    --menu "Choose an option:" 15 60 6 \
    1 "Create New Share" \
    2 "Apply & Restart Samba" \
    3 "Exit" 2> /tmp/menu_choice

  case $(cat /tmp/menu_choice) in
    1) configure_share ;;
    2) apply_share_config ;;
    3) cleanup ;;
  esac
}

configure_share() {
  dialog --backtitle "Samba Share Setup" \
    --form "Enter Share Information" 20 70 10 \
    "Share Name:"     1 1 "$SHARE_NAME" 1 20 30 0 \
    "Share Path:"     2 1 "$SHARE_PATH" 2 20 50 0 \
    "Comment:"        3 1 "$COMMENT"    3 20 50 0 \
    "Guest Access:"   4 1 "$GUEST_OK"   4 20 5  0 \
    2> /tmp/share_basic

  IFS=$'\n' read -r SHARE_NAME SHARE_PATH COMMENT GUEST_OK < /tmp/share_basic

  dialog --mixedform "Advanced Options" 20 70 12 \
    "Read Only [yes/no]:"    1 1 "$READ_ONLY"     1 25 10 0 0 \
    "Browsable [yes/no]:"    2 1 "$BROWSEABLE"    2 25 10 0 0 \
    "Create Mask:"           3 1 "$CREATE_MASK"   3 25 10 0 0 \
    "Directory Mask:"        4 1 "$DIR_MASK"      4 25 10 0 0 \
    "Force User:"            5 1 "$FORCE_USER"    5 25 20 0 0 \
    "Force Group:"           6 1 "$FORCE_GROUP"   6 25 20 0 0 \
    "VFS Objects:"           7 1 "$VFS_OBJECTS"   7 25 20 0 0 \
    2> /tmp/share_advanced

  IFS=$'\n' read -r READ_ONLY BROWSEABLE CREATE_MASK DIR_MASK FORCE_USER FORCE_GROUP VFS_OBJECTS < /tmp/share_advanced

  dialog --checklist "Select Valid Users" 20 60 15 $(for u in $SYSTEM_USERS; do echo "$u" "" off; done) 2> /tmp/valid_users
  VALID_USERS=$(tr -d '"' < /tmp/valid_users)

  create_user_prompt
  preview_share_config
}

create_user_prompt() {
  dialog --yesno "Do you want to create a new Samba user?" 7 50
  if [ $? -eq 0 ]; then
    dialog --inputbox "Enter new system username:" 8 40 2> /tmp/new_user
    NEW_USER=$(cat /tmp/new_user)
    if id "$NEW_USER" >/dev/null 2>&1; then
      echo "User $NEW_USER exists."
    else
      adduser --gecos "" "$NEW_USER"
    fi
    smbpasswd -a "$NEW_USER"
  fi
}

preview_share_config() {
  {
    echo "[$SHARE_NAME]"
    echo "  path = $SHARE_PATH"
    echo "  comment = $COMMENT"
    echo "  guest ok = $GUEST_OK"
    echo "  read only = $READ_ONLY"
    echo "  browseable = $BROWSEABLE"
    echo "  create mask = $CREATE_MASK"
    echo "  directory mask = $DIR_MASK"
    [ -n "$VALID_USERS" ] && echo "  valid users = $VALID_USERS"
    [ -n "$FORCE_USER" ] && echo "  force user = $FORCE_USER"
    [ -n "$FORCE_GROUP" ] && echo "  force group = $FORCE_GROUP"
    [ -n "$VFS_OBJECTS" ] && echo "  vfs objects = $VFS_OBJECTS"
  } > /tmp/share_preview

  dialog --title "Preview Share Configuration" --textbox /tmp/share_preview 20 70

  dialog --yesno "Apply this configuration?" 7 50
  [ $? -eq 0 ] && save_share_config

  dialog --yesno "Create another share?" 7 50
  [ $? -eq 0 ] && configure_share || show_main_menu
}

save_share_config() {
  [ -d "$SHARE_PATH" ] || mkdir -p "$SHARE_PATH" && chmod 0775 "$SHARE_PATH"
  chown nobody:nogroup "$SHARE_PATH"

  [ ! -f "$BACKUP_CONF" ] && cp "$SMB_CONF" "$BACKUP_CONF"
  cat /tmp/share_preview >> "$SMB_CONF"

  log "Added new share: $SHARE_NAME"
}

apply_share_config() {
  dialog --title "Validating Configuration" --msgbox "$(testparm -s 2>&1)" 20 70

  dialog --yesno "Reload Samba now?" 7 50
  if [ $? -eq 0 ]; then
    systemctl reload smbd
    log "Samba reloaded"
  fi

  dialog --msgbox "Samba Share Setup Complete.\n\nLocal IP: $LOCAL_IP\nCheck firewall rules if needed." 10 60
  show_main_menu
}

### MAIN ###
check_dependencies
show_main_menu

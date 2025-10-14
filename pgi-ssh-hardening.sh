#!/usr/bin/env bash
#==========================================
#  OpenSSH CIS hardening (TUI checklist)
#  Backups, selectable actions, validate, optional restart
#  Anton Palamarchuk (info@expice.ru) 14102025
#==========================================
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/root/bin

# Re-exec with bash if started via sh
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' "Requires bash. Re-executing..." >&2
  exec /usr/bin/env bash "$0" "$@"
  printf '%s\n' "Failed to re-exec. Run: bash $0" >&2
  exit 127
fi

# Colors for plain stdout
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'; else RED=''; GRN=''; YLW=''; RST=''; fi

# Root check
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then printf '%s\n' "Run as root."; exit 1; fi

# Binaries
TUI=""
command -v whiptail >/dev/null && TUI="whiptail"
[ -z "$TUI" ] && command -v dialog >/dev/null && TUI="dialog"

# --- TUI theme: green on black ---
if [ "$TUI" = "whiptail" ]; then
  export NEWT_COLORS=$'\
root=,black
roottext=green,black
window=green,black
shadow=black,black
border=green,black
title=brightgreen,black
label=green,black
textbox=green,black
listbox=green,black
actlistbox=black,green
sellistbox=black,green
actsellistbox=black,brightgreen
checkbox=green,black
actcheckbox=black,green
entry=green,black
disentry=green,black
button=black,green
actbutton=black,brightgreen
compactbutton=black,green'
elif [ "$TUI" = "dialog" ]; then
  DIALOGRC_FILE="$(mktemp)"
  cat >"$DIALOGRC_FILE" <<'EOF'
use_colors = on
screen_color          = (GREEN,BLACK,ON)
title_color           = (BRIGHTGREEN,BLACK,ON)
border_color          = (GREEN,BLACK,ON)
dialog_color          = (GREEN,BLACK,ON)
textbox_color         = (GREEN,BLACK,ON)
listbox_color         = (GREEN,BLACK,ON)
actlistbox_color      = (BLACK,GREEN,ON)
sellistbox_color      = (BLACK,GREEN,ON)
actsellistbox_color   = (BLACK,BRIGHTGREEN,ON)
tag_color             = (GREEN,BLACK,ON)
item_color            = (GREEN,BLACK,ON)
checkbox_active_color = (BLACK,GREEN,ON)
button_active_color   = (BLACK,GREEN,ON)
button_inactive_color = (BLACK,GREEN,OFF)
EOF
  export DIALOGRC="$DIALOGRC_FILE"
  trap 'rm -f "$DIALOGRC_FILE"' EXIT
fi

# Targets
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
ISSUE_FILE="/etc/issue.net"
TMOUT_FILE="/etc/profile.d/99-timeout.sh"
AUDIT_DIR="/etc/audit/rules.d"
AUDIT_RULE="${AUDIT_DIR}/50-sshd.rules"
TS="$(date +%Y%m%d-%H%M%S)"

# Guards
if [ ! -f "$SSH_CONFIG_FILE" ]; then
  printf '%s\n' "${RED}sshd_config not found at ${SSH_CONFIG_FILE}. Install openssh-server and rerun.${RST}"
  exit 2
fi

# Helpers
backup_file(){ [ -e "$1" ] && cp -a -- "$1" "$1.bak.${TS}"; }
ensure_option(){
  local key="$1" val="$2" clean="$2"
  clean="${clean%\"}"; clean="${clean#\"}"
  clean="${clean%\'}"; clean="${clean#\'}"
  if grep -Eq "^[[:space:]]*#?[[:space:]]*$key([[:space:]]+|$)" "$SSH_CONFIG_FILE" 2>/dev/null; then
    sed -ri "s|^[[:space:]]*#?[[:space:]]*$key[[:space:]].*|$key $clean|" "$SSH_CONFIG_FILE"
  else
    printf '%s %s\n' "$key" "$clean" >>"$SSH_CONFIG_FILE"
  fi
}
sshd_unit(){ systemctl list-unit-files | grep -q '^ssh\.service' && echo ssh || echo sshd; }
validate_or_restore(){
  local bin; bin="$(command -v sshd || echo /usr/sbin/sshd)"
  if ! "$bin" -t -f "$SSH_CONFIG_FILE" 2>/tmp/sshd_check.err; then
    printf '%s\n' "${RED}[ERROR] sshd_config test failed. Restoring backup.${RST}"
    mv -f "${SSH_CONFIG_FILE}.bak.${TS}" "$SSH_CONFIG_FILE"
    cat /tmp/sshd_check.err
    exit 1
  fi
  rm -f /tmp/sshd_check.err
}

# Backups (all touched files)
backup_file "$SSH_CONFIG_FILE"
backup_file "$ISSUE_FILE"
backup_file "$TMOUT_FILE"
[ -d "$AUDIT_DIR" ] && backup_file "$AUDIT_RULE"

# Checklist selections
CHOICES=()
LOG_LEVEL="INFO"
ALLOW_USERS=""
ALLOW_GROUPS=""

run_cli_checklist(){
  printf '%s\n' "No TUI found (install whiptail or dialog). CLI mode."
  read -rp "Core sshd hardening (y/N)? " a; [[ $a =~ ^[yY]$ ]] && CHOICES+=("CORE")
  read -rp "Key-only auth (PasswordAuthentication no) (y/N)? " a; [[ $a =~ ^[yY]$ ]] && CHOICES+=("KEYONLY")
  read -rp "Disable root login (y/N)? " a; [[ $a =~ ^[yY]$ ]] && CHOICES+=("NOROOT")
  read -rp "Ciphers/MACs/Kex per CIS (y/N)? " a; [[ $a =~ ^[yY]$ ]] && CHOICES+=("ALGS")
  read -rp "Verbose logging (y/N)? " a; [[ $a =~ ^[yY]$ ]] && LOG_LEVEL="VERBOSE"
  read -rp "Set TMOUT=900 (y/N)? " a; [[ $a =~ ^[yY]$ ]] && CHOICES+=("TMOUT")
  read -rp "Create /etc/issue.net banner (y/N)? " a; [[ $a =~ ^[yY]$ ]] && CHOICES+=("BANNER")
  read -rp "Add local audit rule if auditd present (y/N)? " a; [[ $a =~ ^[yY]$ ]] && CHOICES+=("AUDIT")
  read -rp "Fix ~/.ssh permissions (y/N)? " a; [[ $a =~ ^[yY]$ ]] && CHOICES+=("PERMS")
  read -rp "Restrict AllowUsers/AllowGroups (y/N)? " a; if [[ $a =~ ^[yY]$ ]]; then
    CHOICES+=("ALLOW")
    read -rp "AllowUsers (space-separated, empty to skip): " ALLOW_USERS
    read -rp "AllowGroups (space-separated, empty to skip): " ALLOW_GROUPS
  fi
  read -rp "Restart ssh/sshd at end (y/N)? " a; [[ $a =~ ^[yY]$ ]] && CHOICES+=("RESTART")
}

run_tui_checklist(){
  local tf; tf="$(mktemp)"
  if [ "$TUI" = "whiptail" ]; then
    whiptail --title "OpenSSH Hardening" --separate-output \
      --checklist "Select actions:" 22 78 12 \
      CORE     "Core sshd hardening (CIS basics)"           ON \
      KEYONLY  "Key-only auth (PasswordAuthentication no)"  ON \
      NOROOT   "Disable root login"                         ON \
      ALGS     "Ciphers/MACs/Kex per CIS"                   ON \
      LOGVERB  "LogLevel VERBOSE (default INFO)"            OFF \
      TMOUT    "Set TMOUT=900 via /etc/profile.d"           ON \
      BANNER   "Create /etc/issue.net banner"               ON \
      AUDIT    "Local audit rule if auditd present"         ON \
      PERMS    "Fix ~/.ssh and authorized_keys perms"       ON \
      ALLOW    "Restrict AllowUsers/AllowGroups"            OFF \
      RESTART  "Restart ssh/sshd at the end"                OFF \
      2>"$tf" || { rm -f "$tf"; printf '%s\n' "Aborted."; exit 1; }
    mapfile -t CHOICES <"$tf"; rm -f "$tf"
  else
    dialog --title "OpenSSH Hardening" --separate-output \
      --checklist "Select actions:" 22 78 12 \
      CORE     "Core sshd hardening (CIS basics)"           on \
      KEYONLY  "Key-only auth (PasswordAuthentication no)"  on \
      NOROOT   "Disable root login"                         on \
      ALGS     "Ciphers/MACs/Kex per CIS"                   on \
      LOGVERB  "LogLevel VERBOSE (default INFO)"            off \
      TMOUT    "Set TMOUT=900 via /etc/profile.d"           on \
      BANNER   "Create /etc/issue.net banner"               on \
      AUDIT    "Local audit rule if auditd present"         on \
      PERMS    "Fix ~/.ssh and authorized_keys perms"       on \
      ALLOW    "Restrict AllowUsers/AllowGroups"            off \
      RESTART  "Restart ssh/sshd at the end"                off \
      2>"$tf" || { rm -f "$tf"; printf '%s\n' "Aborted."; exit 1; }
    mapfile -t CHOICES <"$tf"; rm -f "$tf"
  fi

  # Extra inputs
  if printf '%s\n' "${CHOICES[@]}" | grep -q '^ALLOW$'; then
    if [ "$TUI" = "whiptail" ]; then
      ALLOW_USERS="$(whiptail --inputbox 'AllowUsers (space-separated, empty to skip):' 10 78 3>&1 1>&2 2>&3 || true)"
      ALLOW_GROUPS="$(whiptail --inputbox 'AllowGroups (space-separated, empty to skip):' 10 78 3>&1 1>&2 2>&3 || true)"
    else
      ALLOW_USERS="$(dialog --inputbox 'AllowUsers (space-separated, empty to skip):' 10 78 3>&1 1>&2 2>&3 || true)"
      ALLOW_GROUPS="$(dialog --inputbox 'AllowGroups (space-separated, empty to skip):' 10 78 3>&1 1>&2 2>&3 || true)"
    fi
  fi
  if printf '%s\n' "${CHOICES[@]}" | grep -q '^LOGVERB$'; then LOG_LEVEL="VERBOSE"; fi
}

# Collect choices
if [ -z "$TUI" ]; then run_cli_checklist; else run_tui_checklist; fi

printf '%s%s%s\n' "$GRN" "Applying selections..." "$RST"

# Actions
if printf '%s\n' "${CHOICES[@]}" | grep -q '^CORE$'; then
  ensure_option ClientAliveInterval         300
  ensure_option ClientAliveCountMax         0
  ensure_option MaxAuthTries                3
  ensure_option X11Forwarding               no
  ensure_option AllowAgentForwarding        no
  ensure_option GSSAPIAuthentication        no
  ensure_option LoginGraceTime              60
  ensure_option MaxSessions                 4
  ensure_option IgnoreRhosts                yes
  ensure_option HostbasedAuthentication     no
  ensure_option PermitEmptyPasswords        no
  ensure_option PermitUserEnvironment       no
  ensure_option UsePAM                      yes
fi

if printf '%s\n' "${CHOICES[@]}" | grep -q '^KEYONLY$'; then
  ensure_option PubkeyAuthentication        yes
  ensure_option PasswordAuthentication      no
fi

if printf '%s\n' "${CHOICES[@]}" | grep -q '^NOROOT$'; then
  ensure_option PermitRootLogin             no
fi

if printf '%s\n' "${CHOICES[@]}" | grep -q '^ALGS$'; then
  ensure_option Ciphers                     chacha20-poly1305@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr
  ensure_option MACs                        hmac-sha2-512,hmac-sha2-256
  ensure_option KexAlgorithms               curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group14-sha256
fi

# Log level
ensure_option LogLevel "$LOG_LEVEL"

# Allow lists
if [ -n "$ALLOW_USERS" ];  then ensure_option AllowUsers  "$ALLOW_USERS"; fi
if [ -n "$ALLOW_GROUPS" ]; then ensure_option AllowGroups "$ALLOW_GROUPS"; fi

# TMOUT
if printf '%s\n' "${CHOICES[@]}" | grep -q '^TMOUT$'; then
  umask 022
  printf '%s\n' "TMOUT=900" "export TMOUT" > "$TMOUT_FILE"
  chmod 0644 "$TMOUT_FILE"
fi

# Banner
if printf '%s\n' "${CHOICES[@]}" | grep -q '^BANNER$'; then
  printf '%s\n' 'Unauthorized access prohibited.' > "$ISSUE_FILE"
  chown root:root "$ISSUE_FILE"
fi

# Audit rule
if printf '%s\n' "${CHOICES[@]}" | grep -q '^AUDIT$'; then
  if [ -d "$AUDIT_DIR" ]; then
    printf '%s\n' '-w /etc/ssh/sshd_config -p wa -k sshd_cfg' > "$AUDIT_RULE"
    { command -v augenrules >/dev/null && augenrules --load; } || \
    { command -v systemctl >/dev/null && systemctl restart auditd 2>/dev/null; } || \
    { command -v service   >/dev/null && service auditd restart 2>/dev/null; } || true
  fi
fi

# Fix perms
if printf '%s\n' "${CHOICES[@]}" | grep -q '^PERMS$'; then
  chown root:root "$SSH_CONFIG_FILE"
  chmod 0600 "$SSH_CONFIG_FILE"
  shopt -s nullglob
  for d in /home/*/.ssh; do chmod 0700 "$d" || true; done
  for f in /home/*/.ssh/authorized_keys; do chmod 0600 "$f" || true; done
  shopt -u nullglob
fi

# Validate
validate_or_restore

# Restart
if printf '%s\n' "${CHOICES[@]}" | grep -q '^RESTART$'; then
  U="$(sshd_unit)"
  printf '%s%s%s\n' "$YLW" "Restarting $U..." "$RST"
  systemctl restart "$U"
  systemctl --no-pager status "$U" --lines=0 || true
else
  printf '%s\n' "Skip restart. Apply later: systemctl restart sshd|ssh"
fi

# Report backups
printf '%s%s%s\n' "$GRN" "Done. Backups:" "$RST"
printf '%s\n' "${SSH_CONFIG_FILE}.bak.${TS}"
[ -e "${ISSUE_FILE}.bak.${TS}" ]  && printf '%s\n' "${ISSUE_FILE}.bak.${TS}"
[ -e "${TMOUT_FILE}.bak.${TS}" ]  && printf '%s\n' "${TMOUT_FILE}.bak.${TS}"
[ -e "${AUDIT_RULE}.bak.${TS}" ]  && printf '%s\n' "${AUDIT_RULE}.bak.${TS}"

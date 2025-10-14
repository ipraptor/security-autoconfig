#!/usr/bin/env bash
#==========================================
#  Automates CIS-compatible hardening OpenSSH:
#  makes backups, edits sshd_config, sets TMOUT,
#  creates a banner, adds a local audit rule,
#  validates the config, and restarts ssh/sshd if agreed.
#
#  Anton Palamarchuk (info@expice.ru) 14102025
#==========================================
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin/:/root/bin

# Re-exec with bash if started via sh
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' "This script requires bash. Re-executing with bash..." >&2
  exec /usr/bin/env bash "$0" "$@"
  printf '%s\n' "Failed to re-exec with bash. Install bash and run: bash $0" >&2
  exit 127
fi

set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/root/bin

# Colors
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'; else RED=''; GRN=''; YLW=''; RST=''; fi

# Root check
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then printf '%s\n' "Run as root."; exit 1; fi

# Targets
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
ISSUE_FILE="/etc/issue.net"
TMOUT_FILE="/etc/profile.d/99-timeout.sh"
AUDIT_DIR="/etc/audit/rules.d"
AUDIT_RULE="${AUDIT_DIR}/50-sshd.rules"
TS="$(date +%Y%m%d-%H%M%S)"

# Require sshd_config to exist
if [ ! -f "$SSH_CONFIG_FILE" ]; then
  printf '%s\n' "${RED}sshd_config not found at ${SSH_CONFIG_FILE}. Install openssh-server and rerun.${RST}"
  exit 2
fi

# Backup helper
backup_file(){ [ -e "$1" ] && cp -a -- "$1" "$1.bak.${TS}"; }

printf '%s\n' "==============================================="
printf '%s%s%s\n' "$RED" "RU: ВНИМАНИЕ! Скрипт изменит sshd_config и создаст резервные копии." "$RST"
printf '%s%s%s\n' "$RED" "EN: ATTENTION! The script will modify sshd_config and create backups." "$RST"
read -r -p "Continue? (y/n): " answer
[[ "$answer" =~ ^[yY]$ ]] || { printf '%s\n' "Aborted."; exit 1; }

printf '%s%s%s\n' "$GRN" "Proceeding..." "$RST"

printf '%s%s%s\n' "$GRN" "Backup..." "$RST"

# Backups
backup_file "$SSH_CONFIG_FILE"
backup_file "$ISSUE_FILE"
backup_file "$TMOUT_FILE"
[ -d "$AUDIT_DIR" ] && backup_file "$AUDIT_RULE"

printf '%s%s%s\n' "$GRN" "Hardening ssh config..." "$RST"
# Ensure/replace option in sshd_config
ensure_option(){
  local key="$1" val="$2"
  if grep -Eq "^[[:space:]]*#?[[:space:]]*$key([[:space:]]+|$)" "$SSH_CONFIG_FILE" 2>/dev/null; then
    sed -ri "s|^[[:space:]]*#?[[:space:]]*$key[[:space:]].*|$key $val|" "$SSH_CONFIG_FILE"
  else
    printf '%s %s\n' "$key" "$val" >>"$SSH_CONFIG_FILE"
  fi
}

# SSH hardening
ensure_option PubkeyAuthentication        yes
ensure_option ClientAliveInterval         300
ensure_option ClientAliveCountMax         0
ensure_option PermitRootLogin             no
# Protocol 2 не задаём (устарело)
ensure_option PasswordAuthentication      no
ensure_option MaxAuthTries                3
ensure_option X11Forwarding               no
ensure_option AllowAgentForwarding        no
ensure_option GSSAPIAuthentication        no
ensure_option LogLevel                    INFO
ensure_option LoginGraceTime              60
ensure_option MaxSessions                 4
ensure_option IgnoreRhosts                yes
ensure_option HostbasedAuthentication     no
ensure_option PermitEmptyPasswords        no
ensure_option PermitUserEnvironment       no
ensure_option UsePAM                      yes
ensure_option Banner                      /etc/issue.net
ensure_option Ciphers                     'chacha20-poly1305@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr'
ensure_option MACs                        'hmac-sha2-512,hmac-sha2-256'
ensure_option KexAlgorithms               'curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group14-sha256'
# ensure_option AllowUsers                 'adminops ansible'
# ensure_option AllowGroups                'sshusers'

# TMOUT
umask 022
printf '%s\n' "TMOUT=900" "export TMOUT" > "$TMOUT_FILE"
chmod 0644 "$TMOUT_FILE"

printf '%s%s%s\n' "$GRN" "Banner create..." "$RST"
# Banner
printf '%s\n' 'Unauthorized access prohibited.' > "$ISSUE_FILE"
chown root:root "$ISSUE_FILE"
chown root:root "$SSH_CONFIG_FILE"
chmod 0600 "$SSH_CONFIG_FILE"

printf '%s%s%s\n' "$GRN" "Create audit rules..." "$RST"
# Local audit rule (optional). Guard for missing auditd.
if [ -d "$AUDIT_DIR" ]; then
  printf '%s\n' '-w /etc/ssh/sshd_config -p wa -k sshd_cfg' > "$AUDIT_RULE"
  { command -v augenrules >/dev/null && augenrules --load; } || \
  { command -v systemctl >/dev/null && systemctl restart auditd 2>/dev/null; } || \
  { command -v service   >/dev/null && service auditd restart 2>/dev/null; } || true
fi

printf '%s%s%s\n' "$GRN" "Fix perms for users directory..." "$RST"
# Fix ~/.ssh perms safely
shopt -s nullglob
for d in /home/*/.ssh; do chmod 0700 "$d" || true; done
for f in /home/*/.ssh/authorized_keys; do chmod 0600 "$f" || true; done
shopt -u nullglob

printf '%s%s%s\n' "$GRN" "Validate SSH settings..." "$RST"
# Validate before restart
SSHD_BIN="$(command -v sshd || echo /usr/sbin/sshd)"
if ! "$SSHD_BIN" -t -f "$SSH_CONFIG_FILE" 2>/tmp/sshd_check.err; then
  printf '%s\n' "${RED}[ERROR] sshd_config test failed. Restoring backup.${RST}"
  mv -f "${SSH_CONFIG_FILE}.bak.${TS}" "$SSH_CONFIG_FILE"
  cat /tmp/sshd_check.err
  exit 1
fi
rm -f /tmp/sshd_check.err

printf '%s\n' "==============================================="
printf '%s%s%s\n' "$YLW" "RU: Перезапустить SSH сейчас? Это включит вход только по ключам и разорвёт текущую сессию!" "$RST"
printf '%s%s%s\n' "$YLW" "EN: Should I restart SSH now? This will enable key-only login and terminate the current session!" "$RST"

read -r -p "Restart SSH? (y/n): " restart_ssh
if [[ "$restart_ssh" =~ ^[yY]$ ]]; then
  UNIT="sshd"; systemctl list-unit-files | grep -q '^ssh\.service' && UNIT="ssh" || true
  printf '%s%s%s\n' "$GRN" "Restarting ${UNIT}..." "$RST"
  systemctl restart "$UNIT"
  systemctl --no-pager status "$UNIT" --lines=0 || true
else
  printf '%s\n' "Restart skipped. Apply later: systemctl restart sshd|ssh"
fi

printf '%s%s%s\n' "$GRN" "Done. Backups:" "$RST"
printf '%s\n' "${SSH_CONFIG_FILE}.bak.${TS}"
[ -e "${ISSUE_FILE}.bak.${TS}" ]  && printf '%s\n' "${ISSUE_FILE}.bak.${TS}"
[ -e "${TMOUT_FILE}.bak.${TS}" ]  && printf '%s\n' "${TMOUT_FILE}.bak.${TS}"
[ -e "${AUDIT_RULE}.bak.${TS}" ]  && printf '%s\n' "${AUDIT_RULE}.bak.${TS}"

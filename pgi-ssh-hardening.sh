#!/usr/bin/env bash
#==========================================
#  OpenSSH CIS hardening — TUI checklist
#  whiptail / CLI fallback, auto-installs TUI if missing
#  Anton Palamarchuk (info@expice.ru) 090726
#==========================================

# MUST come before set -Eeuo — sh has no pipefail
if [ -z "${BASH_VERSION:-}" ]; then
  printf '%s\n' "Requires bash. Re-executing..." >&2
  exec /usr/bin/env bash "$0" "$@"
  printf '%s\n' "Failed to re-exec. Run: bash $0" >&2
  exit 127
fi

set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/bin

# Colors
if [ -t 1 ]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
else
  RED=''; GRN=''; YLW=''; RST=''
fi

# Root check
[[ ${EUID:-$(id -u)} -ne 0 ]] && { printf '%s\n' "Run as root."; exit 1; }

# ─── SSH session lockout warning ─────────────────────────────────────────────
if [[ -n "${SSH_CLIENT:-}${SSH_CONNECTION:-}${SSH_TTY:-}" ]]; then
  printf '\n'
  printf '%s\n' "${RED}╔══════════════════════════════════════════════════════════════╗"
  printf '%s\n' "${RED}║  WARNING: YOU ARE CONNECTED OVER SSH                         ║"
  printf '%s\n' "${RED}║  Key-only auth WITHOUT a working key = PERMANENT LOCKOUT.    ║"
  printf '%s\n' "${RED}║  DO NOT restart SSH unless your key is confirmed working.    ║"
  printf '%s\n' "${RED}╚══════════════════════════════════════════════════════════════╝${RST}"
  printf '\n'
fi

# ─── TUI detection + auto-install ────────────────────────────────────────────
_detect_pkg_manager(){
  local pm
  for pm in apt-get dnf yum zypper pacman apk; do
    command -v "$pm" >/dev/null 2>&1 && { printf '%s' "$pm"; return; }
  done
  printf ''
}

_try_install_whiptail(){
  printf '%s\n' "${YLW}Installing whiptail...${RST}"
  local pm; pm="$(_detect_pkg_manager)"
  case "$pm" in
    apt-get) apt-get install -y -q whiptail ;;
    dnf)     dnf install -y newt ;;
    yum)     yum install -y newt ;;
    zypper)  zypper install -n whiptail ;;
    pacman)  pacman -Sy --noconfirm libnewt ;;
    apk)     apk add --no-cache newt ;;
    *)
      printf '%s\n' "${RED}Unknown package manager. Install whiptail manually.${RST}"
      return 1
      ;;
  esac
}

TUI=""
command -v whiptail >/dev/null 2>&1 && TUI="whiptail"

if [ -z "$TUI" ]; then
  printf '%s\n' "${YLW}whiptail not found.${RST}"
  read -rp "Install whiptail now? (y/N): " _inst
  if [[ $_inst =~ ^[yY]$ ]]; then
    _try_install_whiptail && command -v whiptail >/dev/null 2>&1 && TUI="whiptail"
  fi
  [ -z "$TUI" ] && printf '%s\n' "${YLW}Falling back to CLI mode.${RST}"
fi

# ─── TUI theme (whiptail / NEWT_COLORS) ──────────────────────────────────────
# button/actbutton omitted — ncurses native reverse-video handles button focus
if [ "$TUI" = "whiptail" ]; then
  export NEWT_COLORS=$'root=,black\nroottext=green,black\nwindow=green,black\nshadow=black,black\nborder=green,black\ntitle=brightgreen,black\nlabel=green,black\ntextbox=green,black\nlistbox=green,black\nactlistbox=black,green\nsellistbox=black,green\nactsellistbox=black,brightgreen\ncheckbox=green,black\nactcheckbox=black,green\nentry=green,black\ndisentry=green,black\n'
fi

# ─── Universal yes/no helper ─────────────────────────────────────────────────
_yesno(){
  local title="$1" msg="$2" h="$3" w="$4" _c
  _c=$(whiptail --title "$title" --menu "$msg" $(( h + 2 )) "$w" 2 \
    "Yes" "" "No" "" 3>&1 1>&2 2>&3) || return 1
  [ "$_c" = "Yes" ]
}

# ─── Paths ───────────────────────────────────────────────────────────────────
SSH_CONFIG_FILE="/etc/ssh/sshd_config"
ISSUE_FILE="/etc/issue.net"
TMOUT_FILE="/etc/profile.d/99-timeout.sh"
AUDIT_DIR="/etc/audit/rules.d"
AUDIT_RULE="${AUDIT_DIR}/50-sshd.rules"
TS="$(date +%Y%m%d-%H%M%S)"

[ -f "$SSH_CONFIG_FILE" ] || {
  printf '%s\n' "${RED}sshd_config not found at ${SSH_CONFIG_FILE}. Install openssh-server.${RST}"
  exit 2
}

# ─── Helpers ─────────────────────────────────────────────────────────────────
backup_file(){ [ -e "$1" ] && cp -a -- "$1" "$1.bak.${TS}"; }

ensure_option(){
  local key="$1" val="$2"
  if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}([[:space:]]+|$)" "$SSH_CONFIG_FILE" 2>/dev/null; then
    sed -ri "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "$SSH_CONFIG_FILE"
  else
    printf '%s %s\n' "$key" "$val" >> "$SSH_CONFIG_FILE"
  fi
}

sshd_unit(){
  systemctl list-unit-files 2>/dev/null | grep -q '^ssh\.service' && printf 'ssh' || printf 'sshd'
}

validate_or_restore(){
  local err_f; err_f="$(mktemp)"
  local bin; bin="$(command -v sshd 2>/dev/null || printf '/usr/sbin/sshd')"
  if ! "$bin" -t -f "$SSH_CONFIG_FILE" 2>"$err_f"; then
    printf '%s\n' "${RED}[ERROR] sshd config test FAILED. Restoring backup.${RST}"
    mv -f "${SSH_CONFIG_FILE}.bak.${TS}" "$SSH_CONFIG_FILE"
    cat "$err_f"; rm -f "$err_f"
    exit 1
  fi
  rm -f "$err_f"
}

_count_authorized_keys(){
  local count=0 n f
  shopt -s nullglob
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] || continue
    n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null || true)"
    (( count += n )) || true
  done
  shopt -u nullglob
  printf '%d' "$count"
}

# ─── State ───────────────────────────────────────────────────────────────────
CHOICES=()
LOG_LEVEL="INFO"
ALLOW_USERS=""
ALLOW_GROUPS=""
NEW_USER=""       # username created via _prompt_create_user
NEW_USER_GROUP="" # admin group it was added to (sudo or wheel)

# ─── Temporary item buffer (bash 4.0+ safe, avoids namerefs) ─────────────────
_TMP_ITEMS=()

_build_user_items(){
  _TMP_ITEMS=()
  local uname _pw uid _gid _gecos _home shell presel
  while IFS=: read -r uname _pw uid _gid _gecos _home shell; do
    [[ "$uid" -ge 1000 ]] || continue
    [[ "$shell" =~ /(nologin|false|sync|shutdown|halt)$ ]] && continue
    presel="off"
    [ "$uname" = "${NEW_USER:-}" ] && presel="on"
    _TMP_ITEMS+=("$uname" "UID $uid" "$presel")
  done < /etc/passwd
}

_build_group_items(){
  _TMP_ITEMS=()
  local gname _gpw gid _members presel
  while IFS=: read -r gname _gpw gid _members; do
    if [[ "$gid" -ge 1000 ]] || [[ "$gname" =~ ^(sudo|wheel|ssh|sshusers|adm)$ ]]; then
      presel="off"
      [ "$gname" = "${NEW_USER_GROUP:-}" ] && presel="on"
      _TMP_ITEMS+=("$gname" "GID $gid" "$presel")
    fi
  done < /etc/group
}

# ─── SSH key generation ──────────────────────────────────────────────────────

_generate_key(){
  local username="$1" key_type="$2"

  local home_dir; home_dir="$(getent passwd "$username" 2>/dev/null | cut -d: -f6)"
  if [ -z "${home_dir:-}" ]; then
    printf '%s\n' "${RED}User '$username' not found. Key generation aborted.${RST}"
    return 1
  fi

  local ssh_dir="${home_dir}/.ssh"
  local key_file="${ssh_dir}/id_${key_type}"
  local auth_keys="${ssh_dir}/authorized_keys"

  [ -d "$ssh_dir" ] || { mkdir -p "$ssh_dir"; chmod 0700 "$ssh_dir"; chown "${username}:" "$ssh_dir"; }

  if [ -f "$key_file" ]; then
    printf '%s\n' "${YLW}Key already exists at ${key_file} — overwriting.${RST}"
    rm -f "$key_file" "${key_file}.pub"
  fi

  local -a keygen_args=(-t "$key_type" -f "$key_file" -N ""
                        -C "${username}@$(hostname -s 2>/dev/null || hostname)")
  [ "$key_type" = "rsa" ] && keygen_args+=(-b 4096)

  printf '\n%s\n' "${GRN}Generating ${key_type} key for '${username}'...${RST}"
  ssh-keygen "${keygen_args[@]}"

  cat "${key_file}.pub" >> "$auth_keys"
  chown "${username}:" "$auth_keys" "$key_file" "${key_file}.pub"
  chmod 0600 "$auth_keys" "$key_file"
  chmod 0644 "${key_file}.pub"

  local sep="${RED}══════════════════════════════════════════════════════════════${RST}"
  printf '\n%s\n' "$sep"
  printf '%s\n' "${RED}  COPY THIS PRIVATE KEY TO YOUR CLIENT MACHINE NOW"
  printf '%s\n' "${RED}  Save as:  ~/.ssh/id_${key_type}"
  printf '%s\n' "${RED}  No passphrase — protect the file (chmod 600 on client).${RST}"
  printf '%s\n' "$sep"
  cat "$key_file"
  printf '\n%s\n' "$sep"
  printf '%s\n' "${YLW}  Public key (added to authorized_keys):${RST}"
  cat "${key_file}.pub"
  printf '%s\n' "$sep"
  printf '\n%s\n' "${YLW}After copying, optionally remove the private key from server:${RST}"
  printf '%s\n' "  rm -f ${key_file}"
  printf '\n'
  read -rp "Press Enter after you have saved the private key to your client: "
}

_offer_generate_key(){
  local do_gen=false username="" key_type="ed25519"

  # ── Ask whether to generate ──
  if [ -n "$TUI" ]; then
    local msg="No authorized SSH keys found on this server.\n\nWith key-only auth enabled ALL users will be locked out.\n\nGenerate a new SSH key pair for a user now?"
    _yesno "No SSH keys found" "$msg" 13 66 && do_gen=true || true
  else
    printf '\n%s\n' "${RED}No authorized SSH keys found. Key-only auth will lock out ALL users.${RST}"
    read -rp "Generate a new SSH key pair now? (y/N): " _g
    [[ ${_g:-} =~ ^[yY]$ ]] && do_gen=true
  fi

  if ! $do_gen; then
    printf '\n'
    printf '%s\n' "${RED}╔══════════════════════════════════════════════════════════════╗"
    printf '%s\n' "${RED}║  DANGER: No keys exist. Key-only auth WILL cause lockout.   ║"
    printf '%s\n' "${RED}╚══════════════════════════════════════════════════════════════╝${RST}"
    printf "Continue anyway? Type 'yes': "
    read -rp "" answer
    answer="$(printf '%s' "$answer" | sed 's/[[:space:]]*$//')"
    [ "$answer" = "yes" ] || { printf '%s\n' "Aborted."; exit 1; }
    return
  fi

  # ── Build user menu items (tag + description, no status column) ──
  _build_user_items
  local menu_items=()
  local i=0
  while (( i < ${#_TMP_ITEMS[@]} )); do
    menu_items+=("${_TMP_ITEMS[$i]}" "${_TMP_ITEMS[$((i+1))]}")
    (( i += 3 ))
  done
  # Prepend root if not disabling root login
  printf '%s\n' "${CHOICES[@]}" | grep -q '^NOROOT$' || \
    menu_items=("root" "UID 0 (root)" "${menu_items[@]+"${menu_items[@]}"}")

  local default_user="${NEW_USER:-}"
  [ -z "$default_user" ] && [ "${#menu_items[@]}" -ge 2 ] && default_user="${menu_items[0]}"

  # ── Select user ──
  if [ "${#menu_items[@]}" -eq 0 ]; then
    if [ -n "$TUI" ]; then
      local _in
      _in="$(whiptail --title "Generate key for" --inputbox "Username:" 10 50 \
        "${default_user}" 3>&1 1>&2 2>&3 || true)"
      username="${_in:-}"
    else
      read -rp "  Username [${default_user}]: " _u
      username="${_u:-$default_user}"
    fi
  else
    local n_m=$(( ${#menu_items[@]} / 2 ))
    local lh=$(( n_m > 10 ? 10 : n_m < 3 ? 3 : n_m ))
    local wh=$(( lh + 8 ))
    if [ -n "$TUI" ]; then
      username="$(whiptail --title "Generate SSH key for" \
        --default-item "${default_user}" \
        --menu "Select user (ESC=skip):" $wh 62 $lh "${menu_items[@]}" 3>&1 1>&2 2>&3 || true)"
    else
      local j=0 idx=1 uarr=()
      printf '\n%s\n' "Select user for key generation:"
      while (( j < ${#menu_items[@]} )); do
        local mark=" "; [ "${menu_items[$j]}" = "$default_user" ] && mark="*"
        printf '  %d)%s %s  (%s)\n' "$idx" "$mark" "${menu_items[$j]}" "${menu_items[$((j+1))]}"
        uarr+=("${menu_items[$j]}")
        (( idx++ )); (( j += 2 ))
      done
      printf '  (* = default)\n'
      read -rp "Number or name [${default_user}]: " _sel
      if [[ -z "${_sel:-}" ]]; then
        username="$default_user"
      elif [[ "$_sel" =~ ^[0-9]+$ ]] && (( _sel >= 1 && _sel <= ${#uarr[@]} )); then
        username="${uarr[$((_sel-1))]}"
      else
        username="$_sel"
      fi
    fi
  fi

  username="$(printf '%s' "${username:-}" | tr -d '[:space:]')"
  [[ -z "$username" ]] && { printf '%s\n' "${YLW}No user selected — key generation skipped.${RST}"; return; }

  # ── Select key type ──
  if [ -n "$TUI" ]; then
    local kt
    kt="$(whiptail --title "Key type" --default-item "ed25519" \
      --menu "Select SSH key type:" 12 62 2 \
      "ed25519" "Recommended — modern, compact, fast" \
      "rsa"     "RSA 4096 — legacy client compatibility" \
      3>&1 1>&2 2>&3 || true)"
    [ -n "${kt:-}" ] && key_type="$kt"
  else
    printf '\n%s\n' "Key type:"
    printf '  1) ed25519  (recommended)\n'
    printf '  2) rsa 4096 (legacy)\n'
    read -rp "Choice [1]: " _kt
    [[ "${_kt:-1}" == "2" ]] && key_type="rsa"
  fi

  _generate_key "$username" "$key_type"
}

# ─── Create sudo user (called when NOROOT selected) ──────────────────────────
_prompt_create_user(){
  local do_create=false username=""

  if [ -n "$TUI" ]; then
    _yesno "Avoid lockout" \
      "You selected 'Disable root login'.\n\nCreate a new sudo user now\nto keep server access after root SSH is disabled?" \
      12 64 && do_create=true || true
    $do_create && username="$(whiptail --title "New sudo user" \
      --inputbox "Username:" 10 50 3>&1 1>&2 2>&3 || true)"
  else
    printf '\n%s\n' "${YLW}NOROOT selected — root SSH login will be disabled.${RST}"
    read -rp "Create a new sudo user now to avoid lockout? (y/N): " _cu
    [[ $_cu =~ ^[yY]$ ]] && do_create=true
    if $do_create; then
      read -rp "  New username: " username
    fi
  fi

  username="$(printf '%s' "${username:-}" | tr -d '[:space:]')"
  [[ -z "$username" ]] && return

  if id "$username" >/dev/null 2>&1; then
    printf '%s\n' "${YLW}User '$username' already exists — skipping creation.${RST}"
    NEW_USER="$username"
    return
  fi

  printf '%s\n' "${GRN}Creating user '$username'...${RST}"
  useradd -m -s /bin/bash "$username"
  printf '%s\n' "${GRN}Set a password for '$username':${RST}"
  passwd "$username"

  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "$username"
    NEW_USER_GROUP="sudo"
    printf '%s\n' "${GRN}  → Added to group 'sudo'.${RST}"
  elif getent group wheel >/dev/null 2>&1; then
    usermod -aG wheel "$username"
    NEW_USER_GROUP="wheel"
    printf '%s\n' "${GRN}  → Added to group 'wheel'.${RST}"
  else
    printf '%s\n' "${YLW}  → No sudo/wheel group found. Add '$username' to sudoers manually.${RST}"
  fi

  NEW_USER="$username"
}

# ─── Select AllowUsers from system list ──────────────────────────────────────
_select_allow_users(){
  _build_user_items
  local items=("${_TMP_ITEMS[@]+"${_TMP_ITEMS[@]}"}")

  if [[ ${#items[@]} -eq 0 ]]; then
    if [ -n "$TUI" ]; then
      local _in
      _in="$(whiptail --title "AllowUsers" --inputbox \
        "No login users found. Enter AllowUsers manually (space-separated):" \
        10 70 "${NEW_USER:-}" 3>&1 1>&2 2>&3 || true)"
      ALLOW_USERS="${_in:-}"
    else
      read -rp "  AllowUsers (space-separated, empty to skip): " ALLOW_USERS
    fi
    return
  fi

  local n=$(( ${#items[@]} / 3 ))
  local lh=$(( n > 14 ? 14 : n < 4 ? 4 : n ))
  local wh=$(( lh + 8 ))
  local tf; tf="$(mktemp)"

  if [ -n "$TUI" ]; then
    whiptail --title "AllowUsers" --separate-output \
      --checklist "Select users allowed to connect via SSH (ESC=skip):" \
      $wh 66 $lh "${items[@]}" 2>"$tf" || true
  else
    local i=1 user_arr=()
    printf '\n%s\n' "Available users:"
    local uname _pw uid _gid _gecos _home shell
    while IFS=: read -r uname _pw uid _gid _gecos _home shell; do
      [[ "$uid" -ge 1000 ]] || continue
      [[ "$shell" =~ /(nologin|false|sync|shutdown|halt)$ ]] && continue
      local mark=" "
      [ "$uname" = "${NEW_USER:-}" ] && mark="*"
      printf '  %d)%s %s  (UID %s)\n' "$i" "$mark" "$uname" "$uid"
      user_arr+=("$uname")
      (( i++ ))
    done < /etc/passwd
    printf '  (* = just created)\n'
    read -rp "Enter numbers or names (space-separated, empty=skip): " _sel
    for tok in ${_sel:-}; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#user_arr[@]} )); then
        printf '%s\n' "${user_arr[$((tok-1))]}" >> "$tf"
      else
        printf '%s\n' "$tok" >> "$tf"
      fi
    done
  fi

  ALLOW_USERS="$(tr '\n' ' ' < "$tf" | sed 's/[[:space:]]*$//')"
  rm -f "$tf"
}

# ─── Select AllowGroups from system list ─────────────────────────────────────
_select_allow_groups(){
  _build_group_items
  local items=("${_TMP_ITEMS[@]+"${_TMP_ITEMS[@]}"}")

  if [[ ${#items[@]} -eq 0 ]]; then
    if [ -n "$TUI" ]; then
      local _in
      _in="$(whiptail --title "AllowGroups" --inputbox \
        "No groups found. Enter AllowGroups manually (space-separated):" \
        10 70 "${NEW_USER_GROUP:-}" 3>&1 1>&2 2>&3 || true)"
      ALLOW_GROUPS="${_in:-}"
    else
      read -rp "  AllowGroups (space-separated, empty to skip): " ALLOW_GROUPS
    fi
    return
  fi

  local n=$(( ${#items[@]} / 3 ))
  local lh=$(( n > 14 ? 14 : n < 4 ? 4 : n ))
  local wh=$(( lh + 8 ))
  local tf; tf="$(mktemp)"

  if [ -n "$TUI" ]; then
    whiptail --title "AllowGroups" --separate-output \
      --checklist "Select groups allowed to connect via SSH (ESC=skip):" \
      $wh 66 $lh "${items[@]}" 2>"$tf" || true
  else
    local i=1 group_arr=()
    printf '\n%s\n' "Available groups:"
    local gname _gpw gid _members
    while IFS=: read -r gname _gpw gid _members; do
      if [[ "$gid" -ge 1000 ]] || [[ "$gname" =~ ^(sudo|wheel|ssh|sshusers|adm)$ ]]; then
        local mark=" "
        [ "$gname" = "${NEW_USER_GROUP:-}" ] && mark="*"
        printf '  %d)%s %s  (GID %s)\n' "$i" "$mark" "$gname" "$gid"
        group_arr+=("$gname")
        (( i++ ))
      fi
    done < /etc/group
    printf '  (* = group of newly created user)\n'
    read -rp "Enter numbers or names (space-separated, empty=skip): " _sel
    for tok in ${_sel:-}; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#group_arr[@]} )); then
        printf '%s\n' "${group_arr[$((tok-1))]}" >> "$tf"
      else
        printf '%s\n' "$tok" >> "$tf"
      fi
    done
  fi

  ALLOW_GROUPS="$(tr '\n' ' ' < "$tf" | sed 's/[[:space:]]*$//')"
  rm -f "$tf"
}

# ─── CLI checklist ────────────────────────────────────────────────────────────
run_cli_checklist(){
  printf '%s\n' "─── CLI mode (install whiptail for TUI) ───"
  local a
  read -rp "Core hardening (ClientAlive/MaxAuth/X11/PAM…) (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && CHOICES+=("CORE")
  read -rp "Key-only auth — PasswordAuthentication no (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && CHOICES+=("KEYONLY")
  read -rp "Disable root login (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && CHOICES+=("NOROOT")
  read -rp "Ciphers / MACs / KexAlgorithms per CIS (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && CHOICES+=("ALGS")
  read -rp "LogLevel VERBOSE instead of INFO (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && LOG_LEVEL="VERBOSE"
  read -rp "Set readonly TMOUT=900 via /etc/profile.d (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && CHOICES+=("TMOUT")
  read -rp "Create /etc/issue.net banner + Banner directive (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && CHOICES+=("BANNER")
  read -rp "Add auditd rule for sshd_config if auditd present (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && CHOICES+=("AUDIT")
  read -rp "Fix ~/.ssh and /root/.ssh permissions (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && CHOICES+=("PERMS")
  read -rp "Restrict AllowUsers / AllowGroups (select from list) (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && CHOICES+=("ALLOW")
  read -rp "Restart ssh/sshd at the end (y/N)? " a
  [[ $a =~ ^[yY]$ ]] && CHOICES+=("RESTART")
}

# ─── TUI checklist ───────────────────────────────────────────────────────────
run_tui_checklist(){
  local tf; tf="$(mktemp)"

  local items=(
    CORE    "Core: ClientAlive/MaxAuthTries/X11/PAM/Forwarding"    on
    KEYONLY "Key-only auth (PasswordAuthentication no)"             on
    NOROOT  "Disable root login (PermitRootLogin no)"              on
    ALGS    "Ciphers / MACs / KexAlgorithms per CIS"               on
    LOGVERB "LogLevel VERBOSE (default: INFO)"                     off
    TMOUT   "readonly TMOUT=900 via /etc/profile.d"                on
    BANNER  "Create /etc/issue.net + Banner directive in config"   on
    AUDIT   "Local auditd rule for sshd_config (if auditd exists)" on
    PERMS   "Fix ~/.ssh and /root/.ssh permissions"                on
    ALLOW   "Restrict AllowUsers / AllowGroups (select from list)" off
    RESTART "Restart ssh/sshd at the end"                         off
  )

  whiptail --title "OpenSSH Hardening — Expice Security" \
    --separate-output --checklist "Select hardening actions (ESC=abort):" \
    24 78 12 "${items[@]}" 2>"$tf" \
    || { rm -f "$tf"; printf '%s\n' "Aborted."; exit 1; }

  mapfile -t CHOICES < "$tf"; rm -f "$tf"
  printf '%s\n' "${CHOICES[@]+"${CHOICES[@]}"}" | grep -q '^LOGVERB$' && LOG_LEVEL="VERBOSE" || true
}

# ─── Run checklist ───────────────────────────────────────────────────────────
if [ -z "$TUI" ]; then run_cli_checklist; else run_tui_checklist; fi

if [ ${#CHOICES[@]} -eq 0 ]; then
  printf '%s\n' "Nothing selected. Exiting."
  exit 0
fi

# ─── Post-checklist: create sudo user if NOROOT ──────────────────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^NOROOT$'; then
  _prompt_create_user
fi

# ─── Post-checklist: select AllowUsers/AllowGroups if ALLOW ──────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^ALLOW$'; then
  _select_allow_users
  _select_allow_groups
fi

# ─── Pre-flight: KEYONLY — count keys, offer generation if none ──────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^KEYONLY$'; then
  _KEY_COUNT="$(_count_authorized_keys)"
  if [[ "$_KEY_COUNT" -gt 0 ]]; then
    printf '%s\n' "${GRN}Found ${_KEY_COUNT} authorized key(s) — key-only auth is safe to enable.${RST}"
  else
    _offer_generate_key
  fi
fi

# ─── Backups (BEFORE any modifications) ──────────────────────────────────────
printf '\n%s\n' "${GRN}Creating backups...${RST}"
backup_file "$SSH_CONFIG_FILE"
backup_file "$ISSUE_FILE"
backup_file "$TMOUT_FILE"
[ -d "$AUDIT_DIR" ] && backup_file "$AUDIT_RULE"

printf '%s\n' "${GRN}Applying selections...${RST}"

# ─── CORE hardening ──────────────────────────────────────────────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^CORE$'; then
  # CountMax 3: disconnect after 3 unanswered keepalives (300×3 = 900 s)
  ensure_option ClientAliveInterval     300
  ensure_option ClientAliveCountMax     3
  ensure_option LoginGraceTime          60
  ensure_option MaxAuthTries            3
  ensure_option MaxSessions             4
  ensure_option X11Forwarding           no
  ensure_option AllowAgentForwarding    no
  ensure_option AllowTcpForwarding      no
  ensure_option GatewayPorts            no
  ensure_option PermitTunnel            no
  ensure_option TCPKeepAlive            no
  ensure_option IgnoreRhosts            yes
  ensure_option HostbasedAuthentication no
  ensure_option PermitEmptyPasswords    no
  ensure_option PermitUserEnvironment   no
  ensure_option GSSAPIAuthentication    no
  ensure_option UsePAM                  yes
  ensure_option StrictModes             yes
  ensure_option PrintLastLog            yes
  ensure_option LogLevel                "$LOG_LEVEL"
fi

# ─── Key-only auth ───────────────────────────────────────────────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^KEYONLY$'; then
  ensure_option PubkeyAuthentication   yes
  ensure_option PasswordAuthentication no
fi

# ─── Disable root login ──────────────────────────────────────────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^NOROOT$'; then
  ensure_option PermitRootLogin no
fi

# ─── Crypto (CIS) ────────────────────────────────────────────────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^ALGS$'; then
  ensure_option Ciphers \
    'chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr'
  ensure_option MACs \
    'hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256'
  ensure_option KexAlgorithms \
    'curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group16-sha512,diffie-hellman-group14-sha256'
fi

# ─── AllowUsers / AllowGroups ────────────────────────────────────────────────
[ -n "${ALLOW_USERS:-}"  ] && ensure_option AllowUsers  "$ALLOW_USERS"
[ -n "${ALLOW_GROUPS:-}" ] && ensure_option AllowGroups "$ALLOW_GROUPS"

# ─── TMOUT ───────────────────────────────────────────────────────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^TMOUT$'; then
  if [ -d /etc/profile.d ]; then
    umask 022
    printf '%s\n' "readonly TMOUT=900" "export TMOUT" > "$TMOUT_FILE"
    chmod 0644 "$TMOUT_FILE"
  else
    printf '%s\n' "${YLW}Warning: /etc/profile.d not found — TMOUT skipped.${RST}"
  fi
fi

# ─── Banner ──────────────────────────────────────────────────────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^BANNER$'; then
  printf '%s\n' 'Authorized access only. All sessions are monitored and recorded.' > "$ISSUE_FILE"
  chown root:root "$ISSUE_FILE"
  ensure_option Banner /etc/issue.net
fi

# ─── Audit rule ──────────────────────────────────────────────────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^AUDIT$'; then
  if [ -d "$AUDIT_DIR" ]; then
    printf '%s\n' '-w /etc/ssh/sshd_config -p wa -k sshd_cfg' > "$AUDIT_RULE"
    { command -v augenrules >/dev/null 2>&1 && augenrules --load; } || \
    { command -v systemctl  >/dev/null 2>&1 && systemctl restart auditd 2>/dev/null; } || \
    { command -v service    >/dev/null 2>&1 && service auditd restart 2>/dev/null; } || true
  else
    printf '%s\n' "${YLW}auditd rules dir not found — audit rule skipped.${RST}"
  fi
fi

# ─── Fix permissions ─────────────────────────────────────────────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^PERMS$'; then
  chown root:root "$SSH_CONFIG_FILE"
  chmod 0600      "$SSH_CONFIG_FILE"
  shopt -s nullglob
  for d in /root/.ssh /home/*/.ssh;                              do chmod 0700 "$d" || true; done
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do chmod 0600 "$f" || true; done
  shopt -u nullglob
fi

# ─── Validate (auto-restore on failure) ──────────────────────────────────────
validate_or_restore

# ─── Restart ─────────────────────────────────────────────────────────────────
if printf '%s\n' "${CHOICES[@]}" | grep -q '^RESTART$'; then
  U="$(sshd_unit)"
  printf '\n'
  printf '%s\n' "${RED}╔══════════════════════════════════════════════════════════════╗"
  printf '%s\n' "${RED}║  RESTART WARNING                                             ║"
  printf '%s\n' "${RED}║  • This ends your current SSH session immediately.           ║"
  printf '%s\n' "${RED}║  • After restart, password logins are REJECTED.              ║"
  printf '%s\n' "${RED}║  • If your key doesn't work — you lose server access.        ║"
  printf '%s\n' "${RED}╚══════════════════════════════════════════════════════════════╝${RST}"
  printf "Really restart %s now? Type 'yes' to confirm: " "$U"
  read -rp "" answer
  if [ "$answer" = "yes" ]; then
    printf '%s\n' "${YLW}Restarting ${U}...${RST}"
    if ! systemctl restart "$U" 2>/dev/null; then
      command -v service >/dev/null 2>&1 \
        && service "$U" restart \
        || printf '%s\n' "${RED}Failed. Run manually: systemctl restart $U${RST}"
    fi
    systemctl --no-pager status "$U" --lines=5 2>/dev/null || true
  else
    printf '%s\n' "Restart cancelled. Apply later: systemctl restart sshd|ssh"
  fi
else
  printf '%s\n' "Restart skipped. Apply later: systemctl restart sshd|ssh"
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
printf '\n%s\n' "${GRN}Done.${RST}"
[ -n "${NEW_USER:-}" ] && \
  printf '%s\n' "${GRN}  Created user:  ${NEW_USER}  (group: ${NEW_USER_GROUP:-none})${RST}"
[ -n "${ALLOW_USERS:-}" ]  && printf '%s\n' "  AllowUsers:  ${ALLOW_USERS}"
[ -n "${ALLOW_GROUPS:-}" ] && printf '%s\n' "  AllowGroups: ${ALLOW_GROUPS}"
printf '\n%s\n' "${GRN}Backups:${RST}"
printf '%s\n' "${SSH_CONFIG_FILE}.bak.${TS}"
[ -e "${ISSUE_FILE}.bak.${TS}"  ] && printf '%s\n' "${ISSUE_FILE}.bak.${TS}"
[ -e "${TMOUT_FILE}.bak.${TS}"  ] && printf '%s\n' "${TMOUT_FILE}.bak.${TS}"
[ -e "${AUDIT_RULE}.bak.${TS}"  ] && printf '%s\n' "${AUDIT_RULE}.bak.${TS}"

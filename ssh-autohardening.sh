#!/usr/bin/env bash
#==========================================
#  OpenSSH CIS Audit + Interactive Fix — Expice Security
#  Anton Palamarchuk (info@expice.ru) 080726
#==========================================

if [ -z "${BASH_VERSION:-}" ]; then exec /usr/bin/env bash "$0" "$@"; fi

set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/bin

if [ -t 1 ]; then
  RED=$'\033[31m' GRN=$'\033[32m' YLW=$'\033[33m'
  BLD=$'\033[1m'  DIM=$'\033[2m'  RST=$'\033[0m'
  TICK="${GRN}✓${RST}" CROSS="${RED}✗${RST}"
else
  RED='' GRN='' YLW='' BLD='' DIM='' RST=''
  TICK='OK' CROSS='!!'
fi

[[ ${EUID:-$(id -u)} -ne 0 ]] && { printf '%s\n' "Run as root."; exit 1; }

SSH_CONFIG="/etc/ssh/sshd_config"
TMOUT_FILE="/etc/profile.d/99-timeout.sh"
SSHD_BIN="$(command -v sshd 2>/dev/null || printf '/usr/sbin/sshd')"
TS="$(date +%Y%m%d-%H%M%S)"
KW=28; VW=14   # column widths

[ -f "$SSH_CONFIG" ] || { printf '%s\n' "${RED}sshd_config not found.${RST}"; exit 2; }

_SSHD_T=""
_reload_sshd_t(){ _SSHD_T="$("$SSHD_BIN" -T 2>/dev/null || true)"; }
_reload_sshd_t

_sshd_val(){ printf '%s' "$_SSHD_T" | awk -v k="$1" 'tolower($1)==tolower(k){print $2; exit}'; }

_ensure(){
  local key="$1" val="$2"
  if grep -Eiq "^[[:space:]]*#?[[:space:]]*${key}([[:space:]]+|$)" "$SSH_CONFIG" 2>/dev/null; then
    sed -ri "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|I" "$SSH_CONFIG"
  else
    printf '%s %s\n' "$key" "$val" >> "$SSH_CONFIG"
  fi
}

# ─── Audit state ─────────────────────────────────────────────────────────────
PASS=0; FAIL=0
FAIL_ORDER=()
declare -A FAILED FAILED_CURRENT FAILED_DESC

_reset_state(){
  PASS=0; FAIL=0; FAIL_ORDER=()
  unset FAILED FAILED_CURRENT FAILED_DESC
  declare -gA FAILED FAILED_CURRENT FAILED_DESC
}

_row(){
  local ok="$1" key="$2" actual="$3" expected="$4" desc="$5"
  if [ "$ok" = "1" ]; then
    printf '  [%s] %-*s %s%-*s%s  %s%s%s\n' \
      "$TICK" $KW "$key" "$GRN" $VW "$actual" "$RST" "$DIM" "$desc" "$RST"
    (( PASS++ )) || true
  else
    printf '  [%s] %-*s %s%-*s%s → %s%s%s  %s%s%s\n' \
      "$CROSS" $KW "$key" "$RED" $VW "$actual" "$RST" \
      "$GRN" "$expected" "$RST" "$DIM" "$desc" "$RST"
    (( FAIL++ )) || true
    FAILED["$key"]="$expected"
    FAILED_CURRENT["$key"]="$actual"
    FAILED_DESC["$key"]="$desc"
    FAIL_ORDER+=("$key")
  fi
}

_divider(){ printf '  %s\n' "$(printf '─%.0s' {1..72})"; }
_section(){ printf '\n  %s%s%s\n' "$DIM" "$1" "$RST"; }

# ─── Checks ──────────────────────────────────────────────────────────────────
_chk(){
  local key="$1" expected="$2" desc="$3"
  local actual; actual="$(_sshd_val "$key")"
  local al; al="$(printf '%s' "${actual:-}" | tr '[:upper:]' '[:lower:]')"
  local el; el="$(printf '%s' "$expected"   | tr '[:upper:]' '[:lower:]')"
  [ "$al" = "$el" ] && _row 1 "$key" "${actual:--}" "$expected" "$desc" \
                     || _row 0 "$key" "${actual:-not set}" "$expected" "$desc"
}

_chk_crypto(){
  local key="$1" expected="$2" desc="$3"
  local actual; actual="$(_sshd_val "$key")"
  [ "$actual" = "$expected" ] \
    && _row 1 "$key" "CIS compliant" "$expected" "$desc" \
    || _row 0 "$key" "non-CIS" "$expected" "$desc"
}

_chk_loglevel(){
  local actual; actual="$(_sshd_val "loglevel")"
  local al; al="$(printf '%s' "${actual:-}" | tr '[:upper:]' '[:lower:]')"
  case "$al" in
    info|verbose|debug*) _row 1 "loglevel" "${actual:-INFO}" "INFO+" "Logging level sufficient" ;;
    *) _row 0 "loglevel" "${actual:-not set}" "INFO" "Logging level sufficient" ;;
  esac
}

_chk_banner(){
  local actual; actual="$(_sshd_val "banner")"
  [ -n "${actual:-}" ] && [ "$actual" != "none" ] \
    && _row 1 "banner" "$actual" "/etc/issue.net" "Warning banner on connect" \
    || _row 0 "banner" "${actual:-not set}" "/etc/issue.net" "Warning banner on connect"
}

_chk_tmout(){
  if grep -q 'TMOUT=900' "${TMOUT_FILE}" 2>/dev/null; then
    printf '  [%s] %-*s %s%-*s%s  %s%s%s\n' \
      "$TICK" $KW "TMOUT (profile.d)" "$GRN" $VW "900" "$RST" "$DIM" "Session idle timeout" "$RST"
    (( PASS++ )) || true
  else
    printf '  [%s] %-*s %s%-*s%s → %s%s%s  %s%s%s\n' \
      "$CROSS" $KW "TMOUT (profile.d)" "$RED" $VW "not set" "$RST" \
      "$GRN" "900" "$RST" "$DIM" "Session idle timeout" "$RST"
    (( FAIL++ )) || true
    FAILED["TMOUT"]="900"
    FAILED_CURRENT["TMOUT"]="not set"
    FAILED_DESC["TMOUT"]="Session idle timeout (readonly TMOUT=900 in /etc/profile.d)"
    FAIL_ORDER+=("TMOUT")
  fi
}

_chk_cfg_perms(){
  local p; p="$(stat -c '%a' "$SSH_CONFIG" 2>/dev/null || printf '???')"
  [ "$p" = "600" ] \
    && _row 1 "sshd_config perms" "$p" "600" "Config readable only by root" \
    || _row 0 "sshd_config perms" "$p"  "600" "Config readable only by root"
}

_chk_ssh_dir_perms(){
  local bad=0 dirs=""
  shopt -s nullglob
  for d in /root/.ssh /home/*/.ssh; do
    [ -d "$d" ] || continue
    local dp; dp="$(stat -c '%a' "$d" 2>/dev/null || printf '???')"
    [ "$dp" != "700" ] && { bad=1; dirs="${dirs} ${d}(${dp})"; }
  done
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] || continue
    local fp; fp="$(stat -c '%a' "$f" 2>/dev/null || printf '???')"
    [ "$fp" != "600" ] && { bad=1; dirs="${dirs} ${f}(${fp})"; }
  done
  shopt -u nullglob
  if [ "$bad" -eq 0 ]; then
    _row 1 ".ssh dir/key perms" "700/600" "700/600" ".ssh=700, authorized_keys=600"
  else
    _row 0 ".ssh dir/key perms" "wrong:${dirs}" "700/600" ".ssh=700, authorized_keys=600"
  fi
}

# ─── Pre-flight info ──────────────────────────────────────────────────────────
_KEY_COUNT=-1
_SUDO_COUNT=-1

_count_keys(){
  [ "$_KEY_COUNT" -ge 0 ] && { printf '%d' "$_KEY_COUNT"; return; }
  local count=0 n f
  shopt -s nullglob
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] || continue
    n="$(grep -cE '^(ssh-|ecdsa-|sk-)' "$f" 2>/dev/null || true)"
    (( count += n )) || true
  done
  shopt -u nullglob
  _KEY_COUNT=$count
  printf '%d' "$count"
}

_count_sudo(){
  [ "$_SUDO_COUNT" -ge 0 ] && { printf '%d' "$_SUDO_COUNT"; return; }
  local count=0 members
  for grp in sudo wheel; do
    getent group "$grp" >/dev/null 2>&1 || continue
    members="$(getent group "$grp" | cut -d: -f4)"
    [ -n "$members" ] && (( count += $(printf '%s' "$members" | tr ',' '\n' | grep -c .) )) || true
  done
  _SUDO_COUNT=$count
  printf '%d' "$count"
}

_show_preflight(){
  local kc; kc="$(_count_keys)"
  local sc; sc="$(_count_sudo)"
  local au; au="$(_sshd_val "allowusers")"
  local ag; ag="$(_sshd_val "allowgroups")"

  printf '\n  %sSystem snapshot%s\n' "$BLD" "$RST"
  _divider
  if [ "$kc" -gt 0 ]; then
    printf '  %s✓%s  Authorized SSH keys: %s%d%s\n' "$GRN" "$RST" "$GRN" "$kc" "$RST"
  else
    printf '  %s⚠%s  Authorized SSH keys: %s0 — DANGER if password auth disabled!%s\n' "$RED" "$RST" "$RED" "$RST"
  fi
  if [ "$sc" -gt 0 ]; then
    printf '  %s✓%s  Sudo/wheel users:    %s%d%s\n' "$GRN" "$RST" "$GRN" "$sc" "$RST"
  else
    printf '  %s⚠%s  Sudo/wheel users:    %s0 — DANGER if root login disabled!%s\n' "$RED" "$RST" "$RED" "$RST"
  fi
  printf '  %s   AllowUsers:%s          %s\n' "$DIM" "$RST" "${au:-not set (all users allowed)}"
  printf '  %s   AllowGroups:%s         %s\n' "$DIM" "$RST" "${ag:-not set (all groups allowed)}"
  _divider
}

# ─── CIS crypto values ────────────────────────────────────────────────────────
CIPHERS='chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr'
MACS='hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,hmac-sha2-512,hmac-sha2-256'
KEX='curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group16-sha512,diffie-hellman-group14-sha256'

# ─── Full audit ───────────────────────────────────────────────────────────────
run_audit(){
  _reset_state

  printf '\n  %s%-*s %-*s   %s\n' "$BLD" $KW "CHECK" $VW "CURRENT" "DESCRIPTION$RST"
  _divider

  _section "Authentication"
  _chk pubkeyauthentication    yes  "SSH key auth enabled"
  _chk passwordauthentication  no   "Password login disabled"
  _chk permitrootlogin         no   "Root login disabled"
  _chk permitemptypasswords    no   "Empty passwords blocked"
  _chk permituserenvironment   no   "User env injection blocked"
  _chk gssapiauthentication    no   "GSSAPI/Kerberos disabled"
  _chk ignorerhosts            yes  "Rhosts files ignored"
  _chk hostbasedauthentication no   "Host-based auth disabled"
  _chk usepam                  yes  "PAM integration active"

  _section "Session limits"
  _chk clientaliveinterval     300  "Keepalive interval (s)"
  _chk clientalivecountmax     3    "Missed keepalives → disconnect"
  _chk logingracetime          60   "Login grace period (s)"
  _chk maxauthtries            3    "Max auth attempts"
  _chk maxsessions             4    "Max sessions per connection"

  _section "Forwarding / tunneling"
  _chk x11forwarding           no   "X11 display forwarding"
  _chk allowagentforwarding    no   "SSH agent forwarding"
  _chk allowtcpforwarding      no   "TCP port forwarding"
  _chk gatewayports            no   "Remote port binding"
  _chk permittunnel            no   "VPN tunneling"
  _chk tcpkeepalive            no   "TCP keepalive (spoof risk)"

  _section "Misc"
  _chk strictmodes             yes  "Strict file permission checks"
  _chk printlastlog            yes  "Show last login on connect"
  _chk_loglevel
  _chk_banner
  _chk_tmout

  _section "File permissions"
  _chk_cfg_perms
  _chk_ssh_dir_perms

  _section "Crypto (CIS)"
  _chk_crypto ciphers        "$CIPHERS" "Allowed ciphers"
  _chk_crypto macs           "$MACS"    "Allowed MACs"
  _chk_crypto kexalgorithms  "$KEX"     "Key exchange algorithms"

  _divider
}

# ─── Apply single fix ─────────────────────────────────────────────────────────
_apply_one(){
  local k="$1" v="$2"
  case "$k" in
    TMOUT)
      [ -d /etc/profile.d ] && {
        umask 022
        printf '%s\n' "readonly TMOUT=900" "export TMOUT" > "$TMOUT_FILE"
        chmod 0644 "$TMOUT_FILE"
      } ;;
    banner)
      printf '%s\n' 'Authorized access only. All sessions are monitored and recorded.' \
        > /etc/issue.net
      chown root:root /etc/issue.net
      _ensure Banner /etc/issue.net ;;
    ciphers)           _ensure Ciphers       "$CIPHERS" ;;
    macs)              _ensure MACs          "$MACS" ;;
    kexalgorithms)     _ensure KexAlgorithms "$KEX" ;;
    loglevel)          _ensure LogLevel      "INFO" ;;
    sshd_config\ perms)
      chown root:root "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG" ;;
    .ssh\ dir/key\ perms)
      shopt -s nullglob
      for d in /root/.ssh /home/*/.ssh;                                  do chmod 700 "$d" || true; done
      for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys;  do chmod 600 "$f" || true; done
      shopt -u nullglob ;;
    *) _ensure "$k" "$v" ;;
  esac
}

# ─── Interactive fix loop ────────────────────────────────────────────────────
_fix_interactive(){
  local total=${#FAIL_ORDER[@]}
  local i=0 fixed=0

  for k in "${FAIL_ORDER[@]}"; do
    (( i++ )) || true
    local v="${FAILED[$k]}"
    local cur="${FAILED_CURRENT[$k]:-?}"
    local desc="${FAILED_DESC[$k]:-}"

    printf '\n'
    printf '  ┌── [%d/%d] %s%s%s\n' "$i" "$total" "$BLD" "$k" "$RST"
    printf '  │  %s%s%s\n' "$DIM" "$desc" "$RST"
    printf '  │  Current: %s%s%s  →  Expected: %s%s%s\n' \
      "$RED" "$cur" "$RST" "$GRN" "$v" "$RST"

    # Safety warnings
    case "$k" in
      passwordauthentication)
        local kc; kc="$(_count_keys)"
        if [ "$kc" -eq 0 ]; then
          printf '  │  %s⚠  0 authorized keys found — disabling passwords = LOCKOUT!%s\n' "$RED" "$RST"
        else
          printf '  │  %s✓  %d authorized key(s) found — safe to disable passwords%s\n' "$GRN" "$kc" "$RST"
        fi ;;
      permitrootlogin)
        local sc; sc="$(_count_sudo)"
        if [ "$sc" -eq 0 ]; then
          printf '  │  %s⚠  No sudo/wheel users found — disabling root login = LOCKOUT!%s\n' "$RED" "$RST"
        else
          printf '  │  %s✓  %d sudo/wheel user(s) found — safe to disable root login%s\n' "$GRN" "$sc" "$RST"
        fi ;;
    esac

    local action
    case "$k" in
      TMOUT)                action="Write readonly TMOUT=900 → $TMOUT_FILE" ;;
      banner)               action="Create /etc/issue.net  +  set Banner $SSH_CONFIG" ;;
      ciphers)              action="Set Ciphers (CIS list) in $SSH_CONFIG" ;;
      macs)                 action="Set MACs (CIS list) in $SSH_CONFIG" ;;
      kexalgorithms)        action="Set KexAlgorithms (CIS list) in $SSH_CONFIG" ;;
      loglevel)             action="Set LogLevel INFO in $SSH_CONFIG" ;;
      "sshd_config perms")  action="chown root:root + chmod 600 $SSH_CONFIG" ;;
      ".ssh dir/key perms") action="chmod 700 ~/.ssh dirs, chmod 600 authorized_keys files" ;;
      *)                    action="Set $k $v in $SSH_CONFIG" ;;
    esac
    printf '  │  %sAction:%s %s\n' "$YLW" "$RST" "$action"
    printf '  └──────────────────────────────────────────────────────────────\n'
    read -rp "  [f]ix  [s]kip  [q]uit → " _a </dev/tty || _a="s"
    case "${_a:-s}" in
      f|F)
        _apply_one "$k" "$v"
        printf '  %s→ Applied%s\n' "$GRN" "$RST"
        (( fixed++ )) || true ;;
      q|Q)
        printf '  Quit.\n'; break ;;
      *)
        printf '  %s→ Skipped%s\n' "$DIM" "$RST" ;;
    esac
  done
  printf '\n'
  _FIX_COUNT="$fixed"
}

# ─── Auto-fix (no prompt) ────────────────────────────────────────────────────
_fix_all(){
  local total=${#FAIL_ORDER[@]} i=0
  for k in "${FAIL_ORDER[@]}"; do
    (( i++ )) || true
    local v="${FAILED[$k]}"
    printf '  [%d/%d] %s%-*s%s → applying...\n' "$i" "$total" "$BLD" 28 "$k" "$RST"
    _apply_one "$k" "$v"
    printf '  %s→ Done%s\n' "$GRN" "$RST"
  done
  _FIX_COUNT="$total"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
AUTO_FIX=0
for _arg in "$@"; do
  case "$_arg" in --fix|-f) AUTO_FIX=1 ;; esac
done

printf '\n%s' "$BLD"
printf '  ══════════════════════════════════════════════════════════════════\n'
printf '    OpenSSH Hardening Audit — Expice Security\n'
printf '    %s\n' "$SSH_CONFIG"
printf '  ══════════════════════════════════════════════════════════════════%s\n' "$RST"

_show_preflight

# ── Phase 1: audit ────────────────────────────────────────────────────────────
run_audit

T=$(( PASS + FAIL ))
if [ "$FAIL" -eq 0 ]; then
  printf '\n  %s%s✓ All %d checks passed.%s\n\n' "$BLD" "$GRN" "$T" "$RST"
  exit 0
fi

printf '\n  %sResults: %s%d passed%s  %s%d failed%s  (total %d)\n' \
  "$BLD" "$GRN" "$PASS" "$RST" "$RED" "$FAIL" "$RST" "$T"

# ── Phase 2: fix ──────────────────────────────────────────────────────────────
if [ "$AUTO_FIX" -eq 0 ]; then
  printf '\n'
  read -rp "  [y] fix all  [f] interactive  [n] exit → " _ans </dev/tty || _ans="n"
  case "${_ans:-n}" in
    y|Y) AUTO_FIX=1 ;;
    f|F) AUTO_FIX=0 ;;
    *)   printf '  Skipped.\n'; exit 0 ;;
  esac
fi

cp -a -- "$SSH_CONFIG" "${SSH_CONFIG}.bak.${TS}"
printf '  %sBackup: %s.bak.%s%s\n' "$DIM" "$SSH_CONFIG" "$TS" "$RST"

FIXED=0
if [ "$AUTO_FIX" -eq 1 ]; then
  printf '\n  %sApplying all %d fixes...%s\n\n' "$YLW" "$FAIL" "$RST"
  _fix_all
else
  _fix_interactive
fi
FIXED="$_FIX_COUNT"

if [ "${FIXED:-0}" -gt 0 ]; then
  printf '%s  Validating config...%s\n' "$BLD" "$RST"
  local_err="$(mktemp)"
  if ! "$SSHD_BIN" -t -f "$SSH_CONFIG" 2>"$local_err"; then
    printf '%s\n' "${RED}  Config FAILED — restoring backup.${RST}"
    mv -f "${SSH_CONFIG}.bak.${TS}" "$SSH_CONFIG"
    cat "$local_err"; rm -f "$local_err"; exit 1
  fi
  rm -f "$local_err"
  printf '  %s✓ Config OK%s\n' "$GRN" "$RST"

  # ── Phase 3: re-audit ──────────────────────────────────────────────────────
  printf '\n%s' "$BLD"
  printf '  ══════════════════════════════════════════════════════════════════\n'
  printf '    Re-checking after fixes\n'
  printf '  ══════════════════════════════════════════════════════════════════%s\n' "$RST"

  _reload_sshd_t
  run_audit

  T=$(( PASS + FAIL ))
  if [ "$FAIL" -eq 0 ]; then
    printf '\n  %s%s✓ All %d checks passed.%s\n' "$BLD" "$GRN" "$T" "$RST"
  else
    printf '\n  %sResults: %s%d passed%s  %s%d still failing%s\n' \
      "$BLD" "$GRN" "$PASS" "$RST" "$RED" "$FAIL" "$RST"
  fi
fi

printf '\n  %sRestart SSH to apply: systemctl restart sshd|ssh%s\n\n' "$DIM" "$RST"

#!/usr/bin/env bash
# ============================================================================
# ai-sandbox-remote.sh: the restricted SSH entry point that lets a desktop
# drive ai-sandbox.sh on the Proxmox host without holding a root shell there.
#
# Lives beside ai-sandbox.sh on the host. A desktop key is installed in
# root's authorized_keys as
#
#   restrict,pty,command="/root/ai-sandbox-remote.sh --remote" ssh-ed25519 AAAA... ai-sandbox-remote
#
# so sshd runs THIS script for every connection with that key, whatever the
# client asked for. The client's words arrive in $SSH_ORIGINAL_COMMAND; they
# are split into words (never evaluated by a shell), checked against the
# verb list below, and only then handed to ai-sandbox.sh as plain argv.
# `restrict` turns off port/agent/X11 forwarding; `pty` is re-enabled so
# the work guard's "rescue-archive first? [y/N]" prompt still reaches you.
#
# Remote verbs (what `ssh -i <desktop key> root@pve <verb> ...` may run):
#   agents                    list agent profiles
#   status [agent]            one agent, or every ai-sandbox CT
#   ip     <agent>            current sandbox IP
#   up|down|reset <agent>     the ai-sandbox.sh lifecycle (work guard intact)
#   key                       print the sandbox SSH private key (the one that
#                             opens every sandbox, and nothing else)
#   secret <agent> <NAME>     set NAME=<one line on stdin> in the agent's
#                             secrets.env (mode 600); the value is never
#                             echoed, logged or put on a command line
#   profile <agent>           install a drop-in profile (base64 on stdin);
#                             OFF unless REMOTE_PROFILES=on in config.env,
#                             because a profile runs as root on this host
#   help                      this list
#
# Local use, in a root shell on the host:
#   ai-sandbox-remote.sh install-key [file]   add a desktop public key
#                                             (file, or one line on stdin)
#   ai-sandbox-remote.sh list-keys            show the restricted keys
#   ai-sandbox-remote.sh remove-keys          remove every restricted key
#   ai-sandbox-remote.sh install-script <copy> [path]
#       make ai-sandbox.sh beside this script the copy you already run:
#       link to [path] if given; else keep an existing one; else link to
#       the script the PVE GUI hook shim runs, or to the one git clone of
#       this repo in this directory; else install <copy>. (Run by init.)
#
# Every remote call is logged to syslog (tag ai-sandbox-remote) with the
# client address and verb; secret values and profile bodies never are.
# ============================================================================

set -euo pipefail

SELF="$(readlink -f "$0")"
# The overrides below exist for tests. sshd does not pass the client's
# environment to a forced command (PermitUserEnvironment defaults to no),
# so a desktop cannot set them.
SCRIPT="${AI_SANDBOX_SCRIPT:-$(dirname "$SELF")/ai-sandbox.sh}"
STATE_DIR="${STATE_DIR:-/root/.ai-sandbox}"
AUTH_KEYS="${AUTHORIZED_KEYS:-${HOME:-/root}/.ssh/authorized_keys}"
KEY_TAG="ai-sandbox-remote"
MAX_PROFILE_BYTES=65536
MAX_SECRET_BYTES=4096
BUILTIN_AGENTS=" mistral claude gemini "

die()  { echo "ai-sandbox-remote: $*" >&2; exit 1; }
log()  { logger -t "$KEY_TAG" -- "$*" 2>/dev/null || true; }
valid_agent() { [[ "${1:-}" =~ ^[a-z][a-z0-9]{0,15}$ ]] && [ "$1" != golden ]; }

usage_remote() {
  cat <<'EOF'
ai-sandbox-remote verbs:
  agents | status [agent] | ip <agent> | up <agent> | down <agent> | reset <agent>
  key | secret <agent> <NAME> (value on stdin) | profile <agent> (base64 on stdin) | help
EOF
}

known_agent() {   # $1 = agent; rc 0 when ai-sandbox.sh lists it
  valid_agent "$1" || return 1
  "$SCRIPT" agents 2>/dev/null | awk '{print $1}' | grep -qx -- "$1"
}

need_agent() {   # $1 = agent
  known_agent "$1" || die "unknown agent '${1:-}'; run 'agents' to list them"
}

config_on() {   # $1 = KEY; rc 0 when $STATE_DIR/config.env has KEY=on
  local f="${STATE_DIR}/config.env"
  [ -f "$f" ] || return 1
  # same trust rule as ai-sandbox.sh: only root (the user this runs as) may
  # be able to change it
  [ "$(stat -c %u "$f")" = "$(id -u)" ] || return 1
  case "$(stat -c %a "$f")" in *[2367]? | *?[2367]) return 1 ;; esac
  grep -Eq "^[[:space:]]*$1=[\"']?on[\"']?[[:space:]]*\$" "$f"
}

# --------------------------- remote verbs -----------------------------------

remote_key() {
  local k="${STATE_DIR}/ssh/ai-sandbox"
  [ -f "$k" ] || die "no sandbox keypair yet at $k; run 'up <agent>' once first"
  cat "$k"
}

remote_secret() {   # $1 = agent, $2 = NAME; value = first line of stdin
  local agent="$1" name="$2" val dir file tmp
  need_agent "$agent"
  [[ "$name" =~ ^[A-Z][A-Z0-9_]{0,63}$ ]] || die "invalid secret name '$name' (A-Z, 0-9, _)"
  IFS= read -r val || [ -n "$val" ] || die "no value on stdin"
  # a Windows pipe may add a CR, or a UTF-8 byte-order mark in front
  val="${val%$'\r'}"
  val="${val#$'\xEF\xBB\xBF'}"
  [ -n "$val" ] || die "empty value; nothing changed"
  [ "${#val}" -le "$MAX_SECRET_BYTES" ] || die "value longer than $MAX_SECRET_BYTES bytes; nothing changed"
  # credentials are tokens: refuse anything that could break a KEY=value
  # line or smuggle shell syntax into a profile that is careless with it
  [[ "$val" =~ ^[A-Za-z0-9_.:/+=@-]+$ ]] || die "value has characters a key never contains; nothing changed"
  dir="${STATE_DIR}/${agent}"
  file="${dir}/secrets.env"
  umask 077
  [ -d "$STATE_DIR" ] || install -d -m 700 "$STATE_DIR"
  [ -d "$dir" ] || install -d -m 700 "$dir"
  tmp="$(mktemp "${dir}/.secrets.XXXXXX")"
  if [ -f "$file" ]; then
    grep -v -E "^[[:space:]]*(export[[:space:]]+)?${name}=" "$file" > "$tmp" || true
  fi
  printf '%s=%s\n' "$name" "$val" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
  echo "set $name for $agent in $file (mode 600); it reaches the sandbox on the next 'up $agent'"
}

remote_profile() {   # $1 = agent; base64 profile body on stdin
  local agent="$1" dir dest tmp bak="" out
  valid_agent "$agent" || die "invalid agent name '$agent'"
  case "$BUILTIN_AGENTS" in *" $agent "*) die "'$agent' is a built-in agent; a drop-in cannot replace it" ;; esac
  config_on REMOTE_PROFILES \
    || die "profile upload is off: a drop-in runs as root on the host, so it is opt-in. Set REMOTE_PROFILES=on in ${STATE_DIR}/config.env on the host to allow it"
  dir="${STATE_DIR}/profiles"
  dest="${dir}/${agent}.sh"
  [ -d "$STATE_DIR" ] || install -d -m 700 "$STATE_DIR"
  [ -d "$dir" ] || install -d -m 755 "$dir"
  tmp="$(mktemp)"
  # base64 keeps the bytes exact across Windows PowerShell's pipe encoding;
  # drop line breaks and a byte-order mark's bytes (none are base64 bytes)
  if ! head -c $((MAX_PROFILE_BYTES * 2)) | tr -d '\r\n \357\273\277' | base64 -d > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; die "stdin is not valid base64; nothing changed"
  fi
  [ -s "$tmp" ] || { rm -f "$tmp"; die "empty profile; nothing changed"; }
  [ "$(wc -c < "$tmp")" -le "$MAX_PROFILE_BYTES" ] || { rm -f "$tmp"; die "profile larger than $MAX_PROFILE_BYTES bytes; nothing changed"; }
  bash -n "$tmp" 2>/dev/null || { rm -f "$tmp"; die "profile has a bash syntax error; nothing changed"; }
  if [ -e "$dest" ]; then bak="$(mktemp)"; cp -p "$dest" "$bak"; fi
  install -m 644 "$tmp" "$dest"
  rm -f "$tmp"
  # ai-sandbox.sh checks every drop-in before it sources it; a refusal
  # there stops every command, so roll back rather than leave it in place
  if ! out="$("$SCRIPT" agents 2>&1)" || ! grep -q "^${agent} " <<<"$out"; then
    if [ -n "$bak" ]; then install -m 644 "$bak" "$dest"; rm -f "$bak"; else rm -f "$dest"; fi
    echo "$out" >&2
    die "ai-sandbox.sh refused the profile (output above); the previous state is restored"
  fi
  [ -z "$bak" ] || rm -f "$bak"
  echo "installed $dest"
  grep "^${agent} " <<<"$out"
}

run_remote() {
  local -a w=()
  [ -n "${SSH_ORIGINAL_COMMAND:-}" ] || { usage_remote; exit 0; }
  # split only: read -a does no globbing, expansion or quote processing
  read -r -a w <<<"$SSH_ORIGINAL_COMMAND"
  local verb="${w[0]:-}" n="${#w[@]}" client="${SSH_CLIENT:-local}"
  # the verb and the agent only: never a secret value or a profile body
  log "client=${client%% *} verb=${verb} agent=${w[1]:-}"
  case "$verb" in
    help) usage_remote ;;
    agents)
      [ "$n" -eq 1 ] || die "usage: agents"
      exec "$SCRIPT" agents ;;
    status)
      [ "$n" -le 2 ] || die "usage: status [agent]"
      if [ "$n" -eq 2 ]; then need_agent "${w[1]}"; exec "$SCRIPT" status "${w[1]}"; fi
      exec "$SCRIPT" status ;;
    ip | up | down | reset)
      [ "$n" -eq 2 ] || die "usage: $verb <agent>"
      need_agent "${w[1]}"
      exec "$SCRIPT" "$verb" "${w[1]}" ;;
    key)
      [ "$n" -eq 1 ] || die "usage: key"
      remote_key ;;
    secret)
      [ "$n" -eq 3 ] || die "usage: secret <agent> <NAME>  (value on stdin)"
      remote_secret "${w[1]}" "${w[2]}" ;;
    profile)
      [ "$n" -eq 2 ] || die "usage: profile <agent>  (base64 body on stdin)"
      remote_profile "${w[1]}" ;;
    *)
      die "'${verb}' is not allowed over this key; run 'help'" ;;
  esac
}

# --------------------------- local key management ---------------------------

local_guard() {
  [ "$EUID" -eq 0 ] || [ -n "${AUTHORIZED_KEYS:-}" ] || die "run as root on the Proxmox host"
  [ -z "${SSH_ORIGINAL_COMMAND:-}" ] || die "key management is local only"
}

# On Proxmox VE, /root/.ssh/authorized_keys is usually a symlink to
# /etc/pve/priv/authorized_keys (the cluster filesystem, which syncs it to
# every node and does not support chmod). So never replace the file: create
# it only when it is missing, and rewrite its content in place, through the
# symlink.
ensure_auth_keys() {
  [ -e "$AUTH_KEYS" ] && return 0
  [ -d "$(dirname "$AUTH_KEYS")" ] || install -d -m 700 "$(dirname "$AUTH_KEYS")"
  ( umask 077; : > "$AUTH_KEYS" )
}

write_auth_keys() {   # $1 = temp file with the new content (removed after)
  cat "$1" > "$AUTH_KEYS" || { rm -f "$1"; die "could not write $AUTH_KEYS"; }
  rm -f "$1"
}

install_key() {   # $1 = optional file holding the public key; else stdin
  local line type blob entry tmp
  if [ -n "${1:-}" ]; then IFS= read -r line < "$1" || true; else IFS= read -r line || true; fi
  line="${line%$'\r'}"
  [[ "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]]+([A-Za-z0-9+/]+=*)([[:space:]].*)?$ ]] \
    || die "not an OpenSSH public key line (expected e.g. 'ssh-ed25519 AAAA... comment')"
  type="${BASH_REMATCH[1]}"; blob="${BASH_REMATCH[2]}"
  [[ "$SELF" =~ ^[A-Za-z0-9_./-]+$ ]] || die "refusing: this script's path ($SELF) has characters unsafe in authorized_keys"
  ensure_auth_keys
  # a key that already logs in without the forced command is a full root
  # key; restricting it here would silently cut off its owner's shell
  if grep -F -- " $blob" "$AUTH_KEYS" | grep -vq -- " $KEY_TAG\$"; then
    die "this key already has unrestricted access in $AUTH_KEYS; generate a dedicated key for the desktop (ai-sandbox.ps1 init does)"
  fi
  entry="restrict,pty,command=\"${SELF} --remote\" ${type} ${blob} ${KEY_TAG}"
  tmp="$(mktemp)"
  grep -vF -- " $blob $KEY_TAG" "$AUTH_KEYS" > "$tmp" || true
  printf '%s\n' "$entry" >> "$tmp"
  write_auth_keys "$tmp"
  echo "restricted key installed in $AUTH_KEYS (${type}, verbs only via $SELF)"
}

list_keys() { grep -- " $KEY_TAG\$" "$AUTH_KEYS" 2>/dev/null || echo "(no restricted keys)"; }

remove_keys() {
  local tmp n
  [ -f "$AUTH_KEYS" ] || { echo "(no authorized_keys)"; return 0; }
  n="$(grep -c -- " $KEY_TAG\$" "$AUTH_KEYS" || true)"
  tmp="$(mktemp)"
  grep -v -- " $KEY_TAG\$" "$AUTH_KEYS" > "$tmp" || true
  write_auth_keys "$tmp"
  echo "removed $n restricted key(s) from $AUTH_KEYS"
}

# --------------------------- which ai-sandbox.sh ----------------------------
# The verbs run $SCRIPT (ai-sandbox.sh beside this file). It must be the
# copy the host already uses: a second, curl-style copy would self-update
# from main and, on its next build, point the PVE GUI hook shim at itself
# instead of at your git clone. So link to the existing one when there is
# one; ai-sandbox.sh resolves the link (readlink -f) for every path it uses.

hook_target() {   # the script the PVE hook shim execs, if it still exists
  local f="${HOOK_SNIPPET_DIR:-/var/lib/vz/snippets}/ai-sandbox-hook.sh" p
  [ -f "$f" ] || return 0
  p="$(sed -n 's/^exec \([^ ]*\) hook .*/\1/p' "$f" | head -n 1)"
  [ -n "$p" ] && [ -f "$p" ] && echo "$p"
  return 0
}

find_clone() {   # the one git clone of this repo directly beside $SCRIPT
  local c found="" n=0
  for c in "$(dirname "$SCRIPT")"/*/ai-sandbox.sh; do
    [ -f "$c" ] && [ -e "$(dirname "$c")/.git" ] || continue
    found="$c"; n=$((n + 1))
  done
  if [ "$n" -gt 1 ]; then
    echo "note: several git clones of AI-sandbox beside $SCRIPT; not guessing (init -PveScript <path> picks one)" >&2
    return 0
  fi
  [ -z "$found" ] || echo "$found"
}

link_script() {   # $1 = the ai-sandbox.sh to use
  local real
  real="$(readlink -f "$1")"
  [ "$real" != "$(readlink -f "$SCRIPT" 2>/dev/null || true)" ] || { echo "keeping $SCRIPT (already $real)"; return 0; }
  if [ -f "$SCRIPT" ] && [ ! -L "$SCRIPT" ]; then
    mv -f "$SCRIPT" "${SCRIPT}.bak"
    echo "moved the standalone copy aside: ${SCRIPT}.bak"
  fi
  ln -sfn "$real" "$SCRIPT"
  echo "linked $SCRIPT -> $real (the copy you already run; nothing replaced it)"
}

install_script() {   # $1 = copy to install when none exists; $2 = optional path to use
  local copy="${1:-}" want="${2:-}" t
  if [ -n "$want" ]; then
    [[ "$want" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid path '$want'"
    [ -f "$want" ] || die "no ai-sandbox.sh at $want"
    link_script "$want"
    return 0
  fi
  t="$(hook_target)"
  if [ -e "$SCRIPT" ]; then
    echo "keeping the existing $SCRIPT"
    if [ -n "$t" ] && [ "$(readlink -f "$t")" != "$(readlink -f "$SCRIPT")" ]; then
      echo "warning: the Proxmox GUI hooks run $t, but the desktop would run $SCRIPT." >&2
      echo "  make them one copy: init -PveScript $t (or: ln -sfn $t $SCRIPT)" >&2
    fi
    return 0
  fi
  [ -n "$t" ] || t="$(find_clone)"
  if [ -n "$t" ]; then link_script "$t"; return 0; fi
  [ -f "$copy" ] || die "usage: install-script <copy-of-ai-sandbox.sh> [path]"
  install -m 755 "$copy" "$SCRIPT"
  echo "installed $SCRIPT (no existing ai-sandbox.sh found; this copy self-updates from main)"
}

# --------------------------- dispatch ---------------------------------------
case "${1:-}" in
  --remote)    run_remote ;;
  install-key) local_guard; install_key "${2:-}" ;;
  list-keys)   local_guard; list_keys ;;
  remove-keys) local_guard; remove_keys ;;
  install-script) local_guard; install_script "${2:-}" "${3:-}" ;;
  *) awk 'NR == 1 || /^# ====/ {next} /^set -/ {exit} /^#/ {sub(/^# ?/, ""); print}' "$0"; exit 1 ;;
esac

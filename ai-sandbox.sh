#!/usr/bin/env bash
# ============================================================================
# ai-sandbox.sh — single-use, rebuild-on-demand LXC sandboxes for AI coding
#                 agents on Proxmox VE (Mistral Vibe today; Claude Code,
#                 Gemini CLI and drop-in profiles to follow)
#
# Usage:  ai-sandbox.sh <command> [agent]        (or AGENT=<agent> in env)
#
#   up      <agent>  rebuild + start + provision + print SSH line
#   down    <agent>  clobber disk + park a fresh stopped stub (GUI Start-able)
#   purge   <agent>  destroy completely — no stub, gone from the tree
#   reset   <agent>  down then up (fresh rebuild mid-work)
#   status  [agent]  one sandbox, or every ai-sandbox CT when no agent given
#   shell   <agent>  root shell inside the CT
#   ip      <agent>  current IP (empty if not running)
#   export  <agent>  desktop bundle: keypair + ssh-config (after 'up')
#   agents           list the agent profiles this script knows
#   update           self-update from main (previous copy kept as .bak)
#   hook             INTERNAL — called by the PVE hookscript shim (vmid, phase)
#
# Each agent is its own INSTANCE: own CTID, hostname (ai-sandbox-<agent>),
# MAC, credentials and lock, so several sandboxes can run side by side.
# One SSH keypair serves them all.
#
# Host state lives under $STATE_DIR (default /root/.ai-sandbox):
#   ssh/ai-sandbox[.pub]     sandbox keypair (generated on first build)
#   config.env               optional settings for every instance
#   <agent>/config.env       optional settings for one instance
#   <agent>/secrets.env      the agent's credential (mode 600, never committed)
#   <agent>/mac              retained MAC (generated on first build)
# config.env files hold plain KEY=value lines (never executed). Precedence:
# command-line env > <agent>/config.env > config.env > built-in default.
# Put lasting overrides there: GUI Start/Stop hooks run WITHOUT your shell
# environment, so only the config files reach them.
#
# Design invariants (carried over from mistral-sandbox; README has detail):
#   SINGLE USE      nothing persists between sessions; `up` never resumes
#   GUI-TRAPPED     PVE hookscript: Stop = clobber + fresh stub, Start =
#                   boot that never-booted stub and provision it
#   GUARDED         destroy/clobber only CTs carrying our hostname AND tag
#   WORK-GUARDED    teardown refuses to lose unpushed git work; approved
#                   teardowns are rescue-archived with vzdump first
#   HARDENED        default-deny agent config (connectors/MCP/auto-approve)
#                   plus a host-side PVE egress firewall (lan-block)
#   SELF-UPDATING   build paths sha256-check against main and self-install
#
# Optional: a `provision.sh` beside this script, or <agent>/provision.sh
# under $STATE_DIR, runs INSIDE the fresh CT after base provisioning.
# ============================================================================

set -euo pipefail

# --------------------------- agent & instance --------------------------------
STATE_DIR="${STATE_DIR:-/root/.ai-sandbox}"

die() { echo "error: $*" >&2; exit 1; }

# Read KEY=value lines from a config file WITHOUT executing it. A key already
# set in the environment wins, so command-line overrides beat the file; the
# first file loaded wins over later ones (load the most specific first).
load_config_file() {   # $1 = path
  local file="$1" line key val
  [ -f "$file" ] || return 0
  [ "$(stat -c %u "$file")" = "0" ] || die "refusing $file: not owned by root"
  case "$(stat -c %a "$file")" in
    *[2367]?|*?[2367]) die "refusing $file: group/other-writable" ;;
  esac
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in ''|'#'*) continue ;; esac
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z][A-Z0-9_]*)=(.*)$ ]] \
      || die "bad line in $file: $line"
    key="${BASH_REMATCH[2]}"
    val="${BASH_REMATCH[3]}"
    case "$key" in
      AGENT|STATE_DIR) die "$key cannot be set in $file" ;;
    esac
    # strip one pair of matching surrounding quotes; no expansion, ever
    if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
      val="${BASH_REMATCH[1]}"
    fi
    # plain assignment, NOT export: pct exec passes the host environment
    # into the CT, and config values have no business leaking in there
    [ -n "${!key+x}" ] || printf -v "$key" '%s' "$val"
  done < "$file"
}

valid_agent_name() { [[ "${1:-}" =~ ^[a-z][a-z0-9]{0,15}$ ]]; }
profile_exists()   { valid_agent_name "$1" && declare -F "profile_${1}_meta" >/dev/null; }

# Resolve AGENT, load its profile metadata and config files, then derive the
# instance defaults. Called once per run, before any instance operation.
select_agent() {   # $1 = agent (may be empty: falls back to $AGENT)
  AGENT="${1:-${AGENT:-}}"
  [ -n "$AGENT" ] || die "no agent given - usage: $0 <command> <agent>; known agents: $(list_profiles)"
  profile_exists "$AGENT" || die "unknown agent '$AGENT'; known agents: $(list_profiles)"
  load_config_file "${STATE_DIR}/${AGENT}/config.env"
  load_config_file "${STATE_DIR}/config.env"
  "profile_${AGENT}_meta"
  apply_defaults
}

list_profiles() {
  declare -F | awk '{print $3}' | sed -n 's/^profile_\([a-z][a-z0-9]*\)_meta$/\1/p' | paste -sd' ' -
}

# --------------------------- configuration ---------------------------------
# Instance-independent settings first; per-instance ones in apply_defaults.
SANDBOX_TAG="${SANDBOX_TAG:-ai-sandbox}"   # ownership tag; guard_ct() enforces it
HOOK_VOL_ID="local:snippets/ai-sandbox-hook.sh"
HOOK_SNIPPET_DIR="${HOOK_SNIPPET_DIR:-/var/lib/vz/snippets}"
AUTO_UPDATE="${AUTO_UPDATE:-on}"        # on = build paths self-check against main; off = never check
RAW_URL="${RAW_URL:-https://raw.githubusercontent.com/itsfja/AI-sandbox/main/ai-sandbox.sh}"
SHARED_LOCK="/run/lock/ai-sandbox.shared.lock"   # template/key/hook setup across instances
GUARD_STAMP_TTL=600                   # seconds a work-guard pass remains valid
STORAGE_CFG="${STORAGE_CFG:-/etc/pve/storage.cfg}"  # storage definitions (content/path lookup)
FW_DIR="${FW_DIR:-/etc/pve/firewall}" # Proxmox firewall config dir (contains cluster.fw & <CTID>.fw)

apply_defaults() {
  CTID="${CTID:-$PROFILE_CTID}"        # fixed ID per agent = one sandbox per agent
  CTHOST="ai-sandbox-${AGENT}"         # derived, not configurable: the hook maps it back to the agent
  CORES="${CORES:-4}"
  RAM_MB="${RAM_MB:-4096}"
  SWAP_MB="${SWAP_MB:-2048}"
  DISK_GB="${DISK_GB:-40}"
  STORAGE="${STORAGE:-local-lvm}"      # storage for rootfs
  BRIDGE="${BRIDGE:-vmbr0}"
  TEMPLATE="${TEMPLATE:-}"             # empty = auto-pick newest Debian 12 template
  SSH_PUBKEY="${SSH_PUBKEY:-}"         # optional override; empty = managed keypair
  SSH_KEY_FILE="${SSH_KEY_FILE:-${STATE_DIR}/ssh/ai-sandbox}"   # shared by all instances
  INSTANCE_DIR="${STATE_DIR}/${AGENT}"
  MAC_FILE="${MAC_FILE:-${INSTANCE_DIR}/mac}"
  CT_MAC="${CT_MAC:-}"                 # optional override; empty = managed MAC
  SECRETS_FILE="${SECRETS_FILE:-${INSTANCE_DIR}/secrets.env}"
  HOOK="${HOOK:-on}"                   # on = attach PVE hookscript (GUI trap)
  CLOBBER="${CLOBBER:-discard}"        # discard | zero | off - post-stop rootfs wipe
  EXPORT_DIR="${EXPORT_DIR:-/root/ai-sandbox-export/${AGENT}}"
  LOCK_FILE="/run/lock/ai-sandbox.${AGENT}.lock"
  GUARD_STAMP="/run/lock/ai-sandbox.${AGENT}.workguard-ok"
  STUB_MARKER="${INSTANCE_DIR}/pristine-stub"   # "this stopped CT has never booted"
  FORCE="${FORCE:-0}"                  # 1 = skip the work-loss guard prompt (still rescue-archives)
  RESCUE="${RESCUE:-1}"                # 1 = vzdump before an approved guarded teardown
  RESCUE_STORAGE="${RESCUE_STORAGE:-auto}"   # ordered storage IDs; "auto" = first with backup content
  RESCUE_KEEP="${RESCUE_KEEP:-2}"      # rescue archives of this CT to keep
  AGENT_HARDEN="${AGENT_HARDEN:-on}"   # on = inject the profile's default-deny config
  AGENT_CONNECTORS="${AGENT_CONNECTORS:-off}"     # account/app connectors
  AGENT_MCP="${AGENT_MCP:-off}"                   # MCP servers
  AGENT_AUTO_APPROVE="${AGENT_AUTO_APPROVE:-off}" # auto-approve / YOLO / bypass modes
  FIREWALL="${FIREWALL:-on}"           # on = attach PVE firewall=1 and write per-CT rules
  EGRESS_POLICY="${EGRESS_POLICY:-lan-block}"     # lan-block | strict | off
  EGRESS_ALLOW="${EGRESS_ALLOW:-}"     # optional comma-separated IPs/CIDRs allowed outbound
  PROVISION_HOOKS=("$(dirname "$(readlink -f "$0")")/provision.sh" "${INSTANCE_DIR}/provision.sh")
  [[ "$CTID" =~ ^[0-9]+$ ]] && [ "$CTID" -ge 100 ] || die "invalid CTID '$CTID'"
}

# --------------------------- agent profiles ----------------------------------
# A profile is five functions named profile_<agent>_<part>:
#   meta          set PROFILE_CTID, PROFILE_LABEL, PROFILE_VSCODE_EXT
#   install       print a bash snippet that installs the CLI (runs in the CT
#                 as root, after the base toolchain; /root/.local/bin is on PATH)
#   verify        print the command that proves the CLI works (e.g. --version)
#   credentials   push $SECRETS_FILE into the CT in the agent's native form
#   policy        inject the default-deny config from AGENT_CONNECTORS,
#                 AGENT_MCP and AGENT_AUTO_APPROVE (only when AGENT_HARDEN=on)
#   credentials_hint   (optional) how to create $SECRETS_FILE, shown when absent
# Helpers for profiles: ct_push_file <src> <dest> <mode>, bool_word on|off.

# ---- mistral: Mistral Vibe CLI ----------------------------------------------
profile_mistral_meta() {
  PROFILE_CTID=1051
  PROFILE_LABEL="Mistral Vibe CLI"
  PROFILE_VSCODE_EXT="mistralai.mistral-vibe-code"
}

profile_mistral_install() {
  cat <<'EOF'
# current Vibe CLI, fetched at build time
curl -LsSf https://mistral.ai/vibe/install.sh | bash
# make the CLI reachable from non-login shells
ln -sf /root/.local/bin/vibe     /usr/local/bin/vibe     2>/dev/null || true
ln -sf /root/.local/bin/vibe-acp /usr/local/bin/vibe-acp 2>/dev/null || true
EOF
}

profile_mistral_verify() { echo "vibe --version"; }

# secrets.env holds MISTRAL_API_KEY=<key> (a *Vibe* key from chat.mistral.ai,
# Code > Vibe CLI — a Studio key lacks the Vibe Code entitlement). The CLI
# reads /root/.vibe/.env on startup.
profile_mistral_credentials() {
  ct_push_file "$SECRETS_FILE" /root/.vibe/.env 600
  echo "credentials injected (host: $SECRETS_FILE -> CT: /root/.vibe/.env)"
}

profile_mistral_credentials_hint() {
  echo "  create a Vibe key at chat.mistral.ai (Code > Vibe CLI), then run:"
  echo "    printf 'MISTRAL_API_KEY=<key>\\n' > $SECRETS_FILE && chmod 600 $SECRETS_FILE"
}

profile_mistral_policy() {
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Managed by ai-sandbox.sh — override at build time via AGENT_CONNECTORS /
# AGENT_MCP / AGENT_AUTO_APPROVE, or AGENT_HARDEN=off to skip.
enable_connectors = $(bool_word "$AGENT_CONNECTORS")
enable_mcp = $(bool_word "$AGENT_MCP")
enable_auto_approve = $(bool_word "$AGENT_AUTO_APPROVE")
EOF
  ct_push_file "$tmp" /root/.vibe/config.toml 400 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  echo "hardening: injected /root/.vibe/config.toml"
}

# --------------------------- helpers ---------------------------------------

lock_or_die() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another ai-sandbox operation is running on the $AGENT sandbox (serial per agent)"
}

# Hook phases fire from INSIDE the pct call of the operation that already
# holds the serial lock: `up` runs `pct create --start` (pre-start and
# post-start fire under up's lock), `down`/`purge` run `pct stop`
# (post-stop fires under theirs), a GUI Start/Stop runs under nobody's.
# A hook phase must therefore never DEMAND the lock (lock_or_die) — when
# `up` builds, the pre-start hook would abort the very start it is part
# of. Instead: lock free = standalone/GUI task, take it and do the
# phase's work; lock held = the holder IS the operation whose pct call
# triggered this hook and it does that work itself — pass through
# quietly with exit 0.
hook_lock() {   # $1 = phase; rc 0 = lock acquired (do the work), rc 1 = passthrough
  exec 9>"$LOCK_FILE"
  if flock -n 9; then
    return 0
  fi
  echo "ai-sandbox: $AGENT operation in progress - $1 hook passthrough" >&2
  return 1
}

# Self-update: the script is installed by hand (curl one-liner), so local
# copies drift silently — bugs fixed on main keep biting a stale host
# copy (that is literally how #10 went undetected). Design:
#   * build paths only (`up` and the GUI pre-start hook) self-check
#     against main (RAW_URL) via a sha256 comparison; status/ip/shell
#     stay instant and network-free.
#   * stale -> install the current copy (bash -n validated, previous
#     copy kept as $0.bak, atomic mv: a concurrently running instance
#     keeps executing the old inode undisturbed) and re-exec ONCE
#     (AI_SANDBOX_SELF_UPDATED guard), so the build that noticed the
#     drift runs current code.
#   * the check never blocks: an unreachable URL, a timeout, or a
#     fetched file that fails bash -n all degrade to a warning and the
#     current (old) script proceeds.
#   * AUTO_UPDATE=off disables the automatic check entirely; the
#     `update` subcommand performs the same install explicitly.
#   * hand-edited local copies are overwritten on build paths (the
#     edits land in the .bak); patch locally only with AUTO_UPDATE=off.

fetch_current_script() {   # $1 = dest path, $2 = curl timeout (s)
  curl -fsSL -m "${2:-15}" "$RAW_URL" > "$1" 2>/dev/null && bash -n "$1"
}

install_current_script() {   # $1 = temp file holding the new script; echoes backup path
  local self new mode
  self="$(readlink -f "$0")"
  new="$1"
  mode="$(stat -c %a "$self")"
  cp -a "$self" "${self}.bak"
  chmod "$mode" "$new"
  mv -f "$new" "$self"
  echo "${self}.bak"
}

self_check() {   # "$@" = full original argv; installs + re-execs once if stale
  [ "$AUTO_UPDATE" = "on" ] || return 0
  [ -z "${AI_SANDBOX_SELF_UPDATED:-}" ] || return 0
  local tmp bak
  tmp="$(mktemp 2>/dev/null)" || { echo "self-check: mktemp failed - skipping" >&2; return 0; }
  if ! fetch_current_script "$tmp" 15; then
    rm -f "$tmp"
    echo "self-check: could not fetch/validate $RAW_URL - continuing with the current script" >&2
    return 0
  fi
  if [ "$(sha256sum "$(readlink -f "$0")" | awk '{print $1}')" = "$(sha256sum "$tmp" | awk '{print $1}')" ]; then
    rm -f "$tmp"
    return 0
  fi
  bak="$(install_current_script "$tmp")"
  echo "self-update: local script was stale - installed the current copy from main"
  echo "  (previous copy: $bak); re-running on the new script"
  export AI_SANDBOX_SELF_UPDATED=1
  exec "$(readlink -f "$0")" "$@"
}

# Permanent, script-managed SSH keypair, retained on the HOST across
# rebuilds (same pattern as the credential store). Generated once on the
# first `up`; the public half is injected into every fresh CT. The private
# key never leaves the host and never enters any repository.
# With SSH_PUBKEY set, the override is used and no key is generated.
ensure_ssh_key() {
  if [ -n "$SSH_PUBKEY" ]; then
    [ -f "$SSH_PUBKEY" ] || die "no SSH public key at $SSH_PUBKEY (set SSH_PUBKEY)"
    SSH_KEY_FILE=""
    return 0
  fi
  if [ ! -f "$SSH_KEY_FILE" ]; then
    mkdir -p "$(dirname "$SSH_KEY_FILE")"
    chmod 700 "$(dirname "$SSH_KEY_FILE")"
    ssh-keygen -t ed25519 -N "" -C "ai-sandbox" -f "$SSH_KEY_FILE" >/dev/null
    echo "generated sandbox keypair (retained on host): $SSH_KEY_FILE"
  fi
  chmod 600 "$SSH_KEY_FILE"
  SSH_PUBKEY="${SSH_KEY_FILE}.pub"
}

# Permanent, script-managed MAC, retained on the HOST across rebuilds
# (same pattern as the keypair). Without a pinned hwaddr, every recreate
# would get a fresh random MAC from PVE, which silently breaks DHCP
# reservations. Generated once on the first build; pinned on every
# recreate. With CT_MAC set, the override is used and none is generated.
ensure_mac() {
  [ -n "$CT_MAC" ] && return 0
  if [ -s "$MAC_FILE" ]; then
    CT_MAC="$(cat "$MAC_FILE")"
  else
    # locally administered unicast (02:xx:xx:xx:xx:xx), otherwise random
    CT_MAC="02:$(od -An -N5 -tx1 /dev/urandom | tr -d ' \n' | sed 's/../&:/g;s/:$//')"
    mkdir -p "$(dirname "$MAC_FILE")"
    printf '%s\n' "$CT_MAC" > "$MAC_FILE"
    chmod 600 "$MAC_FILE"
    echo "generated sandbox MAC (retained on host): $CT_MAC"
  fi
  echo "$CT_MAC" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' \
    || die "invalid MAC '$CT_MAC' in $MAC_FILE - delete the file or set CT_MAC"
}

# Auto-deploy the PVE hookscript shim (idempotent). The shim only forwards
# (vmid, phase) to this script's internal `hook` subcommand.
ensure_hook_snippet() {
  [ "$HOOK" = "on" ] || return 0
  local self
  self="$(readlink -f "$0")"
  mkdir -p "$HOOK_SNIPPET_DIR"
  printf '#!/usr/bin/env bash\n# ai-sandbox PVE hookscript shim - auto-generated, safe to overwrite\n# one shim serves every agent instance; the script maps vmid -> agent\nvmid="$1"; phase="$2"\nexec %q hook "$vmid" "$phase"\n' \
    "$self" > "${HOOK_SNIPPET_DIR}/ai-sandbox-hook.sh"
  chmod +x "${HOOK_SNIPPET_DIR}/ai-sandbox-hook.sh"
}

# Setup shared by every instance (keypair, template download, hook shim),
# serialised across instances with a SHORT blocking lock: per-agent locks
# let two agents build in parallel, but they must not race the first-ever
# keypair generation or the same template download. Holds no pct calls,
# so a hook phase can never wait on it from inside its own operation.
shared_setup() {
  exec 8>"$SHARED_LOCK"
  flock -w 900 8 || die "timed out waiting for shared setup lock $SHARED_LOCK"
  ensure_ssh_key
  [ -n "$TEMPLATE" ] || TEMPLATE="$(template_auto)"
  ensure_hook_snippet
  flock -u 8
  exec 8>&-
}

# Run a command inside the CT with a fixed, clean root environment.
# `pct exec` (lxc-attach) passes the CALLER's environment into the CT:
# from a shell that is your HOME/LANG/exported overrides, from a PVE
# hookscript it is almost nothing (no HOME - the Vibe installer dies on
# that under set -u). Either way builds would differ by how they were
# started; env -i makes CLI `up` and GUI Start provision identically.
CT_ENV=(env -i HOME=/root USER=root LOGNAME=root SHELL=/bin/bash TERM=dumb
  LANG=C.UTF-8 PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin)
ct_run() { pct exec "$CTID" -- "${CT_ENV[@]}" "$@"; }

# Copy a host file into the CT as root:root with the given mode, creating
# the destination directory. Streams the file through `pct exec` (stdin)
# rather than `pct push`: push takes the CT's config lock, which Proxmox
# holds for the whole Start task — post-start hook included — so a push
# from GUI-Start provisioning times out. exec goes straight to lxc-attach.
# The file is created under umask 077 and only then given its final mode,
# so a secret is never briefly world-readable.
ct_push_file() {   # $1 = host src, $2 = CT dest path, $3 = octal mode
  ct_run sh -c 'umask 077 && mkdir -p "$(dirname "$1")" && cat > "$1" && chown root:root "$1" && chmod "$2" "$1"' \
    sh "$2" "$3" < "$1"
}

template_auto() {
  pveam update >/dev/null 2>&1 || true
  local t
  t="$(pveam available --section system 2>/dev/null \
       | awk '/debian-12-standard/ {print $2}' | tail -n1)"
  [ -n "$t" ] || die "no debian-12 template found; set TEMPLATE manually"
  # download if not already present. The >&2 is load-bearing: this function
  # is consumed via TEMPLATE="$(template_auto)", and pveam download prints
  # its whole verbose progress (downloading/wget/checksum) to stdout —
  # without the redirect that log is captured into TEMPLATE and pct create
  # rejects the oversized ostemplate ("value may only be 255 characters
  # long"). stderr passes through $(...) to the terminal, so the progress
  # stays visible live.
  pveam list local 2>/dev/null | grep -q "${t##*/}" || pveam download local "$t" >&2
  echo "local:vztmpl/${t##*/}"
}

ct_exists()  { pct status "$CTID" >/dev/null 2>&1; }
ct_running() { [ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" = "running" ]; }

sandbox_ip() {
  pct exec "$CTID" -- sh -c 'hostname -I 2>/dev/null | cut -d" " -f1' 2>/dev/null || true
}

wait_for_ip() {
  local ip="" i
  for i in $(seq 1 45); do
    ip="$(sandbox_ip)"
    [ -n "$ip" ] && { echo "$ip"; return 0; }
    sleep 2
  done
  return 1
}

# --------------------------- work-loss guard ----------------------------------
# "Disposable" must never silently mean "destroys your unpushed commits".
# Every teardown that kills a RUNNING sandbox (up / down / purge, GUI Stop
# or Restart via the hookscript) first scans it for git repos holding work
# that exists nowhere outside the CT: modified or staged files, meaningful
# new files, or commits not on any remote. Findings abort the teardown —
# interactive default-No confirm, fail-closed when unattended — unless
# FORCE=1. A pass is stamped in /run: the hookscript's pre-stop runs as a
# separate PVE process WITHOUT the caller's environment, so a fresh stamp
# is the only way it can know an interactive guard already said yes.

sandbox_work_findings() {   # echoes findings for a running CT; empty = clean
  ct_running || return 0
  ct_run bash -c '
    command -v git >/dev/null 2>&1 || exit 0
    find /root /home -maxdepth 4 -type d -name .git 2>/dev/null |
    while IFS= read -r g; do
      repo="${g%/.git}"
      cd "$repo" 2>/dev/null || continue
      dirty="$(git status --porcelain 2>/dev/null | grep -cv "^??")"
      new="$(git status --porcelain 2>/dev/null | grep "^??" |
        grep -cvE "(\.pytest_cache|__pycache__|node_modules|\.venv|\.mypy_cache|\.ruff_cache|/dist/|/build/|\.DS_Store)")"
      unpushed="$(git rev-list --count --all --not --remotes 2>/dev/null)" ||
        unpushed=0
      [ "${dirty:-0}" -gt 0 ] || [ "${new:-0}" -gt 0 ] ||
        [ "${unpushed:-0}" -gt 0 ] || continue
      printf "  %s: %s modified, %s new, %s unpushed\n" \
        "$repo" "$dirty" "$new" "$unpushed"
    done
  ' 2>/dev/null
}

storage_cfg_value() {   # $1 = storage name, $2 = key (content|path) from $STORAGE_CFG
  awk -v s="$1" -v key="$2" '
    /^[A-Za-z0-9]+: / { sec = ($2 == s) }
    sec && $1 == key { print $2; exit }
  ' "$STORAGE_CFG" 2>/dev/null
}

rescue_storage_autodetect() {   # first non-local storage with backup content; local fallback
  # Detection happens in $STORAGE_CFG: pvesm status prints no Content
  # column, so it cannot tell which storages accept backups. Prefer the
  # first non-local storage with backup content; fall back to local
  # (archives share the host boot disk) with the caveat logged.
  local pick
  pick="$(awk '
    /^[A-Za-z0-9]+: / { name = $2 }
    name && $1 == "content" && $2 ~ /(^|,)backup(,|$)/ {
      if (name != "local" && !printed) { print name; printed = 1 }
      if (name == "local") fallback = 1
    }
    END { if (!printed && fallback) print "local" }
  ' "$STORAGE_CFG" 2>/dev/null)"
  if [ -z "$pick" ]; then
    return 1
  fi
  if [ "$pick" = "local" ]; then
    echo "rescue: only 'local' has backup content; archives share the host boot disk" >&2
  fi
  echo "$pick"
}

rescue_storage() {   # rescue backup storage: ordered preference list of IDs / "auto"
  local list="${RESCUE_STORAGE:-auto}" candidate contents pick saved_ifs
  saved_ifs="$IFS"
  IFS=','
  for candidate in $list; do
    IFS="$saved_ifs"
    candidate="$(printf '%s' "$candidate" | tr -d ' \t')"
    [ -n "$candidate" ] || continue
    if [ "$candidate" = "auto" ]; then
      pick="$(rescue_storage_autodetect)"
      if [ -n "$pick" ]; then
        echo "$pick"
        return 0
      fi
      echo "rescue: 'auto' found no storage with backup content in $STORAGE_CFG" >&2
      continue
    fi
    contents="$(storage_cfg_value "$candidate" content)"
    case ",${contents}," in
      *",backup,"*)
        echo "$candidate"
        return 0
        ;;
    esac
    echo "rescue: '$candidate' has no backup content ($STORAGE_CFG says '${contents:-nothing}'), skipping" >&2
  done
  IFS="$saved_ifs"
  echo "rescue: no usable storage in RESCUE_STORAGE='$list'; use an ordered list of storage IDs with backup content, or add 'auto'" >&2
  return 1
}

rescue_archive() {   # vzdump the CT to rescue storage before an approved teardown
  [ "$RESCUE" = "1" ] || {
    echo "rescue: RESCUE=0 - proceeding without an archive" >&2
    return 0
  }
  ct_exists || return 0
  local storage out archive path dumpdir old
  storage="$(rescue_storage)" || return 1
  echo "rescue: archiving CT $CTID to '$storage' before teardown ..."
  if ! out="$(vzdump "$CTID" --mode stop --storage "$storage" --compress zstd 2>&1)"; then
    echo "$out" >&2
    echo "rescue: vzdump failed - nothing was destroyed" >&2
    return 1
  fi
  archive="$(printf '%s\n' "$out" | sed -n "s/.*creating vzdump archive '\([^']*\)'.*/\1/p" | head -n 1)"
  echo "rescue: archive created${archive:+: $archive}"
  # retention: keep only the newest RESCUE_KEEP archives of this CT
  path="$(storage_cfg_value "$storage" path)"
  [ -n "$path" ] || return 0   # e.g. PBS storage manages its own retention
  dumpdir="$path/dump"
  ls -1t "$dumpdir"/vzdump-lxc-"$CTID"-*.tar.* 2>/dev/null |
    tail -n +"$((RESCUE_KEEP + 1))" |
    while read -r old; do
      rm -f "$old" "${old%.tar.*}.log"
      echo "rescue: pruned old archive $(basename "$old")"
    done
}

guard_stamp_ok() {   # true when the last guard pass is fresher than the TTL
  [ -f "$GUARD_STAMP" ] || return 1
  local age
  age="$(( $(date +%s) - $(stat -c %Y "$GUARD_STAMP" 2>/dev/null || echo 0) ))"
  [ "$age" -le "$GUARD_STAMP_TTL" ]
}

work_guard() {   # $1 = teardown label (up|down|purge|pre-stop); fail-closed
  local findings ans label="${1:-teardown}"
  if guard_stamp_ok; then
    touch "$GUARD_STAMP" 2>/dev/null || true
    return 0
  fi
  findings="$(sandbox_work_findings)"
  if [ -z "$findings" ]; then
    touch "$GUARD_STAMP" 2>/dev/null || true
    return 0
  fi
  echo "work guard ($label): the sandbox holds work that exists nowhere else:" >&2
  echo "$findings" >&2
  if [ "$FORCE" = "1" ]; then
    echo "work guard ($label): FORCE=1 - rescue-archiving, then proceeding" >&2
  elif [ -t 0 ] && [ -t 1 ]; then
    read -r -p "tearing it down loses it. Rescue-archive it first, then proceed? [y/N] " ans
    case "$ans" in
      y | Y | yes | Yes | YES) ;;
      *)
        echo "aborted: push or extract the work, or re-run with FORCE=1" >&2
        return 1
        ;;
    esac
  else
    echo "no terminal attached: aborting $label (push/extract, or FORCE=1)" >&2
    return 1
  fi
  # Approval given. Stamp BEFORE vzdump: its stop-mode stop triggers the
  # pre-stop hook, which must see a fresh stamp to let the backup's stop through.
  touch "$GUARD_STAMP" 2>/dev/null || true
  if ! rescue_archive; then
    rm -f "$GUARD_STAMP" 2>/dev/null || true
    die "work guard: rescue archive failed - nothing was destroyed. Fix backup storage (RESCUE_STORAGE), or RESCUE=0 to destroy without an archive"
  fi
  return 0
}

# Ownership interlock: EVERY destructive operation must pass this gate.
# The sandbox is identified by BOTH the sandbox hostname AND the ownership
# tag on the CT config. A same-ID collision — some other system squatting
# on $CTID by design or by operator error — aborts loudly instead of being
# destroyed. Pre-tagging sandboxes are recognized (and healed) only when
# they also carry this script's managed hookscript.
guard_ct() {
  ct_exists || return 0
  local cfg hostname tags
  cfg="$(pct config "$CTID")"
  hostname="$(echo "$cfg" | awk '/^hostname:/ {print $2}')"
  tags="$(echo "$cfg" | awk '/^tags:/ {print $2}')"
  if [ "$hostname" = "$CTHOST" ] && echo "$tags" | grep -qw "$SANDBOX_TAG"; then
    return 0
  fi
  # legacy sandbox from before tagging: our hostname AND our hookscript
  if [ "$hostname" = "$CTHOST" ] && echo "$cfg" | grep -q "^hookscript: ${HOOK_VOL_ID}$"; then
    echo "guard: untagged legacy sandbox found - tagging CT $CTID as '$SANDBOX_TAG'"
    pct set "$CTID" --tags "${tags:+${tags};}${SANDBOX_TAG}"
    return 0
  fi
  die "refusing to touch CT $CTID: it is not this script's sandbox (hostname '$hostname', tags '${tags:-none}'; expected hostname '$CTHOST' with tag '$SANDBOX_TAG'). If that CT is something else, move it or set CTID to a free ID; only if you are CERTAIN it is an old sandbox, tag it manually: pct set $CTID --tags $SANDBOX_TAG"
}

destroy_sandbox() {
  guard_ct   # ownership interlock: never destroy a CT that is not ours
  work_guard destroy || die "work guard: refusing to destroy CT $CTID"
  clear_stub_marker   # whatever comes next is not the parked stub
  if ct_exists; then
    ct_running && pct stop "$CTID"
    pct destroy "$CTID" --purge
    echo "destroyed CT $CTID"
  fi
}

# --------------------------- connector & egress hardening --------------------
# Isolating compute/filesystem does not contain information flow if outbound
# connectors are enabled or if the CT can probe/reach internal LAN services.
# Layer 1 (in-CT guardrail): the agent profile's default-deny config,
# disabling connectors, MCP servers, and auto-approve by default.
# Layer 2 (host boundary): Proxmox per-CT firewall ruleset enforced on the
# hypervisor bridge — outside container root control.

FW_MARKER="# ai-sandbox managed firewall"

validate_on_off() {   # $1 = var name, $2 = value
  case "$2" in
    on|off) return 0 ;;
    *) die "invalid $1='$2' (expected 'on' or 'off')" ;;
  esac
}

validate_cidr_or_ip() {   # $1 = token; strict IPv4/IPv6 or CIDR validation (blocks .fw rule injection)
  local token="$1" addr prefix o1 o2 o3 o4
  # Full-string regex (rejects newlines, whitespace, comments, and metacharacters)
  [[ "$token" =~ ^[0-9A-Fa-f.:/]+$ ]] || return 1
  if [[ "$token" == *.* ]]; then
    # IPv4 or IPv4/prefix
    if [[ "$token" == */* ]]; then
      addr="${token%%/*}"
      prefix="${token#*/}"
      [[ "$prefix" =~ ^[0-9]{1,2}$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1
    else
      addr="$token"
    fi
    [[ "$addr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    o1="${BASH_REMATCH[1]}"; o2="${BASH_REMATCH[2]}"
    o3="${BASH_REMATCH[3]}"; o4="${BASH_REMATCH[4]}"
    [ "$o1" -le 255 ] && [ "$o2" -le 255 ] && [ "$o3" -le 255 ] && [ "$o4" -le 255 ] || return 1
    return 0
  elif [[ "$token" == *:* ]]; then
    # IPv6 or IPv6/prefix
    if [[ "$token" == */* ]]; then
      addr="${token%%/*}"
      prefix="${token#*/}"
      [[ "$prefix" =~ ^[0-9]{1,3}$ ]] && [ "$prefix" -ge 0 ] && [ "$prefix" -le 128 ] || return 1
    else
      addr="$token"
    fi
    # Require valid hex groups (1-4 hex digits), no :::, at most one ::, not bare ":"
    [[ "$addr" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [ "$addr" != ":" ] || return 1
    [[ "$addr" != *:::* ]] || return 1
    local stripped="${addr/::/}"
    [[ "$stripped" != *::* ]] || return 1
    [[ "$addr" =~ [0-9A-Fa-f] ]] || [ "$addr" = "::" ] || return 1
    [[ ! "$addr" =~ [0-9A-Fa-f]{5} ]] || return 1
    return 0
  fi
  return 1
}

validate_hardening_config() {
  validate_on_off AGENT_HARDEN "$AGENT_HARDEN"
  validate_on_off AGENT_CONNECTORS "$AGENT_CONNECTORS"
  validate_on_off AGENT_MCP "$AGENT_MCP"
  validate_on_off AGENT_AUTO_APPROVE "$AGENT_AUTO_APPROVE"
  validate_on_off FIREWALL "$FIREWALL"
  case "$EGRESS_POLICY" in
    lan-block|strict|off) ;;
    *) die "invalid EGRESS_POLICY='$EGRESS_POLICY' (expected 'lan-block', 'strict', or 'off')" ;;
  esac
  if [ -n "$EGRESS_ALLOW" ]; then
    local saved_ifs="$IFS" entry
    IFS=','
    for entry in $EGRESS_ALLOW; do
      IFS="$saved_ifs"
      entry="$(printf '%s' "$entry" | tr -d ' \t')"
      [ -n "$entry" ] || continue
      validate_cidr_or_ip "$entry" || die "invalid IP/CIDR '$entry' in EGRESS_ALLOW"
    done
    IFS="$saved_ifs"
  fi
}

bool_word() {   # on|off -> true|false (valid in TOML and JSON alike)
  [ "$1" = "on" ] && echo "true" || echo "false"
}

firewall_active() {
  [ "$FIREWALL" = "on" ] && [ "$EGRESS_POLICY" != "off" ]
}

datacenter_firewall_enabled() {
  local cluster_fw="${FW_DIR}/cluster.fw"
  [ -f "$cluster_fw" ] || return 1
  awk '
    /^\[/ { in_opt = ($0 ~ /^\[OPTIONS\][[:space:]]*$/); next }
    in_opt && /^[[:space:]]*enable:[[:space:]]*1([[:space:]]*(#.*)?)?$/ { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$cluster_fw" 2>/dev/null
}

warn_datacenter_firewall() {
  firewall_active || return 0
  datacenter_firewall_enabled && return 0
  echo "warning: Proxmox Datacenter firewall is disabled (${FW_DIR}/cluster.fw) - per-CT egress rules in ${FW_DIR}/${CTID}.fw are NOT enforced yet." >&2
  echo "  to enable safely: ensure host SSH (22) & PVE UI (8006) access, then set Datacenter > Firewall > Options > Firewall: Yes." >&2
}

render_firewall_rules() {
  local policy_out="ACCEPT"
  [ "$EGRESS_POLICY" = "strict" ] && policy_out="DROP"
  cat <<EOF
${FW_MARKER} (CT ${CTID}, EGRESS_POLICY=${EGRESS_POLICY})
[OPTIONS]
enable: 1
dhcp: 1
policy_in: DROP
policy_out: ${policy_out}

[RULES]
IN ACCEPT -p tcp -dport 22 -log nolog # sandbox SSH
OUT ACCEPT -p udp -sport 68 -dport 67 -log nolog # DHCP client
OUT ACCEPT -p udp -dport 53 -log nolog # DNS (UDP)
OUT ACCEPT -p tcp -dport 53 -log nolog # DNS (TCP)
EOF
  if [ -n "$EGRESS_ALLOW" ]; then
    local saved_ifs="$IFS" entry
    IFS=','
    for entry in $EGRESS_ALLOW; do
      IFS="$saved_ifs"
      entry="$(printf '%s' "$entry" | tr -d ' \t')"
      [ -n "$entry" ] || continue
      printf 'OUT ACCEPT -dest %s -log nolog # EGRESS_ALLOW\n' "$entry"
    done
    IFS="$saved_ifs"
  fi
  if [ "$EGRESS_POLICY" = "lan-block" ]; then
    cat <<'EOF'
OUT DROP -dest 10.0.0.0/8 -log nolog # block RFC1918 LAN
OUT DROP -dest 172.16.0.0/12 -log nolog # block RFC1918 LAN
OUT DROP -dest 192.168.0.0/16 -log nolog # block RFC1918 LAN
OUT DROP -dest 169.254.0.0/16 -log nolog # block link-local / metadata
OUT DROP -dest 100.64.0.0/10 -log nolog # block CGNAT
OUT DROP -dest fc00::/7 -log nolog # block IPv6 ULA
OUT DROP -dest fe80::/10 -log nolog # block IPv6 link-local
EOF
  fi
}

configure_firewall() {
  validate_hardening_config
  local fw_file="${FW_DIR}/${CTID}.fw" tmp_file
  if ! firewall_active; then
    if [ -f "$fw_file" ] && grep -qF "$FW_MARKER" "$fw_file" 2>/dev/null; then
      rm -f "$fw_file"
      echo "firewall: disabled (removed managed ruleset $fw_file)"
    fi
    return 0
  fi
  if [ -f "$fw_file" ] && ! grep -qF "$FW_MARKER" "$fw_file" 2>/dev/null; then
    die "refusing to overwrite unmanaged firewall ruleset at $fw_file - remove it or set FIREWALL=off"
  fi
  mkdir -p "$FW_DIR"
  # Atomic same-directory rename avoids partial writes on pmxcfs (/etc/pve)
  tmp_file="${FW_DIR}/.${CTID}.fw.tmp.$$"
  if ! render_firewall_rules > "$tmp_file"; then
    rm -f "$tmp_file"
    die "failed to write firewall ruleset temp file $tmp_file"
  fi
  mv -f "$tmp_file" "$fw_file"
  echo "firewall: wrote host-enforced ruleset $fw_file (EGRESS_POLICY=$EGRESS_POLICY)"
}

remove_firewall() {
  local fw_file="${FW_DIR}/${CTID}.fw"
  if [ -f "$fw_file" ] && grep -qF "$FW_MARKER" "$fw_file" 2>/dev/null; then
    rm -f "$fw_file"
    echo "firewall: removed managed ruleset $fw_file"
  fi
}

# Layer 1 dispatch: the agent profile renders and pushes its own
# default-deny config. A failed push aborts the build (fail closed).
inject_agent_policy() {
  if [ "$AGENT_HARDEN" != "on" ]; then
    echo "hardening: AGENT_HARDEN=off - skipping the $PROFILE_LABEL policy config"
    return 0
  fi
  "profile_${AGENT}_policy" || die "hardening: failed to inject the $PROFILE_LABEL policy config"
}

print_hardening_summary() {
  local fw_state="off" agent_state="off"
  if firewall_active; then
    if datacenter_firewall_enabled; then
      fw_state="${EGRESS_POLICY} (active)"
    else
      fw_state="${EGRESS_POLICY} (pending Datacenter firewall)"
    fi
  fi
  if [ "$AGENT_HARDEN" = "on" ]; then
    agent_state="connectors=${AGENT_CONNECTORS}, mcp=${AGENT_MCP}, auto_approve=${AGENT_AUTO_APPROVE}"
  fi
  echo "hardening: firewall=${fw_state}; ${AGENT}=(${agent_state})"
}

# Create the sandbox CT. $1 = start | stopped. The hookscript is attached
# whenever HOOK=on so the GUI trap works on every incarnation, stub included.
# The ownership tag is set here; guard_ct() enforces it before any destroy.
# The retained MAC is pinned via hwaddr so DHCP reservations survive rebuilds.
# When firewall_active, the host-side PVE ruleset is written BEFORE pct create
# and net0 carries firewall=1 so there is no unfiltered boot window.
create_sandbox() {
  local hookargs=() startargs=() net0_opts
  validate_hardening_config
  ensure_mac
  configure_firewall
  net0_opts="name=eth0,bridge=${BRIDGE},ip=dhcp${CT_MAC:+,hwaddr=$CT_MAC}"
  firewall_active && net0_opts="${net0_opts},firewall=1"
  [ "$HOOK" = "on" ] && hookargs=(--hookscript "$HOOK_VOL_ID")
  [ "${1:-start}" = "start" ] && startargs=(--start 1)
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CTHOST" \
    --cores "$CORES" --memory "$RAM_MB" --swap "$SWAP_MB" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "$net0_opts" \
    --unprivileged 1 \
    --features nesting=1 \
    --ssh-public-keys "$SSH_PUBKEY" \
    --tags "$SANDBOX_TAG" \
    --onboot 0 \
    "${hookargs[@]}" \
    "${startargs[@]}"
}

# Wipe the rootfs of the STOPPED CT (keep the disk object, destroy the data).
clobber_disk() {
  [ "$CLOBBER" = "off" ] && return 0
  guard_ct   # ownership interlock: never wipe a CT that is not ours
  local line volid dev
  line="$(pct config "$CTID" 2>/dev/null | awk '/^rootfs:/')" || true
  volid="$(echo "$line" | cut -d' ' -f2 | cut -d, -f1)"
  [ -n "$volid" ] || { echo "clobber: no rootfs volid found, skipping"; return 0; }
  dev="$(pvesm path "$volid" 2>/dev/null || true)"
  case "$dev" in
    /dev/*) ;;
    *) echo "clobber: $volid is not /dev-backed ($dev) - skipping wipe" >&2; return 0 ;;
  esac
  if [ "$CLOBBER" = "zero" ]; then
    echo "clobber: zero-filling $dev ..."
    dd if=/dev/zero of="$dev" bs=1M status=none || true
  else
    # -f is required: util-linux >= 2.36 refuses a device that still holds
    # a filesystem signature (the rootfs always does) whenever stdin is a
    # terminal, so an interactive `down` would silently skip the wipe.
    local err
    err="$(blkdiscard -f "$dev" 2>&1)" \
      || echo "clobber: blkdiscard failed on $dev: ${err:-unknown error} - set CLOBBER=zero to overwrite instead" >&2
  fi
}

# Stop-then-park: clobber the disk, destroy the CT, recreate a pristine
# stopped stub (Start-able in the GUI, hook attached).
park_sandbox() {
  ct_running && pct stop "$CTID"
  clobber_disk
  destroy_sandbox
  shared_setup
  create_sandbox stopped
  mark_stub_pristine
}

# Pristine-stub marker. GUI Start cannot rebuild the CT: Proxmox holds the
# CT's config lock (/run/lock/lxc/pve-config-<CTID>.lock) for the whole
# Start task, pre-start hook included, so any pct destroy/create from the
# hook waits on its own task and times out. Instead, every park (down, GUI
# Stop) leaves a freshly created, never-booted stub and records that here;
# pre-start only lets a stub carrying this mark boot. The mark lives under
# STATE_DIR (survives a host reboot) and is cleared by any destroy and by
# pre-start itself, so a disk that has ever booted never counts as fresh.
mark_stub_pristine() {
  mkdir -p "$(dirname "$STUB_MARKER")"
  printf '%s\n' "$CTID" > "$STUB_MARKER"
}

clear_stub_marker() { rm -f "$STUB_MARKER"; }

stub_is_pristine() {
  [ -f "$STUB_MARKER" ] && [ "$(cat "$STUB_MARKER" 2>/dev/null)" = "$CTID" ] \
    && ct_exists && ! ct_running
}

# The stub's net0 firewall flag was fixed when it was parked; if FIREWALL or
# EGRESS_POLICY changed since, the CT config would need editing, which
# pre-start cannot do under Proxmox's lock.
stub_firewall_consistent() {
  local net0
  net0="$(pct config "$CTID" 2>/dev/null | awk '/^net0:/ {print $2}')"
  if firewall_active; then
    [[ ",${net0}," == *",firewall=1,"* ]]
  else
    [[ ",${net0}," != *",firewall=1,"* ]]
  fi
}

# Provisioning script, executed INSIDE the fresh CT on every build: an
# agent-neutral baseline, then the profile's install snippet (current CLI
# release at build time — no pinning, by design), then its verify command.
# Anything beyond this, the agent installs itself at runtime.
provision_script() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# runs under ct_run's clean environment (HOME=/root, LANG=C.UTF-8, PATH
# with /root/.local/bin first, where uv-style installers put CLIs);
# C locale keeps apt/perl quiet in a fresh CT
export LC_ALL=C
export PATH="/root/.local/bin:$PATH"

# general-purpose baseline: the agent extends this at runtime as needed
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  ca-certificates curl wget git build-essential \
  python3 python3-pip python3-venv \
  unzip zip jq ripgrep man-db sudo locales || true


# root access is by the injected keypair ONLY: the template ships root's
# password locked and the script never sets one; pin key-only root login
# explicitly (the Debian default, made unconditional here) so a template
# change can never quietly enable password auth. Needs the template's
# Include of sshd_config.d (Debian ships it).
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/10-ai-sandbox-root-key-only.conf
sshd -t && systemctl reload ssh >/dev/null 2>&1 || true

# ---- agent profile: install ----
EOF
  "profile_${AGENT}_install"
  echo
  echo "# ---- agent profile: verify ----"
  "profile_${AGENT}_verify"
}

# Re-inject the agent's permanent credential store into the fresh CT, in
# whatever form its profile wants (env file, settings, token file...).
inject_credentials() {
  if [ ! -f "$SECRETS_FILE" ]; then
    echo "warning: no credential store at $SECRETS_FILE - $PROFILE_LABEL will need its own sign-in" >&2
    if declare -F "profile_${AGENT}_credentials_hint" >/dev/null; then
      "profile_${AGENT}_credentials_hint" >&2
    fi
    return 0
  fi
  [ "$(stat -c %a "$SECRETS_FILE")" = "600" ] || chmod 600 "$SECRETS_FILE"
  "profile_${AGENT}_credentials" || die "failed to inject credentials for $PROFILE_LABEL"
}

# Shared post-build provisioning: baseline + agent CLI + credentials +
# policy + optional user hooks (script dir, then the instance dir).
provision_and_report() {
  echo "provisioning base toolchain and $PROFILE_LABEL ..."
  local prov hook
  prov="$(mktemp)"
  provision_script > "$prov"
  ct_push_file "$prov" /root/provision-base.sh 700
  ct_run bash /root/provision-base.sh
  rm -f "$prov"

  # permanent credential store -> fresh CT, every build
  inject_credentials

  # default-deny agent config (connectors, MCP, auto-approve)
  inject_agent_policy

  # user hooks (deterministic per-use extras), if present
  for hook in "${PROVISION_HOOKS[@]}"; do
    [ -f "$hook" ] || continue
    echo "running user provisioning hook $hook ..."
    ct_push_file "$hook" /root/provision.sh 700
    ct_run bash /root/provision.sh
  done
}

print_ssh_line() {
  local ip="${1:-$(sandbox_ip)}"
  if [ -n "$SSH_KEY_FILE" ]; then
    echo "  ssh -i ${SSH_KEY_FILE} root@${ip}"
  else
    echo "  ssh root@${ip}"
  fi
}

# Every rebuild mints a fresh SSH host key, so a stale known_hosts
# entry for the sandbox IP on the HOST makes the ssh line above die
# with REMOTE HOST IDENTIFICATION HAS CHANGED on the second rebuild.
# Purge the stale entry at generation time; strict host-key checking
# stays fully on for every other host.
purge_known_hosts() {   # $1 = sandbox IP
  [ -n "${1:-}" ] || return 0
  ssh-keygen -R "$1" >/dev/null 2>&1 || true
}

# --------------------------- subcommands ------------------------------------
cmd_up() {
  self_check up "$AGENT"
  lock_or_die
  validate_hardening_config
  # AUTO REBUILD: never resume — tear down any prior sandbox first
  destroy_sandbox

  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  shared_setup

  echo "building $AGENT sandbox (CT $CTID, $PROFILE_LABEL) from $TEMPLATE ..."
  create_sandbox start

  local ip
  ip="$(wait_for_ip)" || { echo "container started but no IP (check ${BRIDGE}/DHCP)"; exit 1; }

  # fresh host key per rebuild: drop the stale host-side entry now
  purge_known_hosts "$ip"

  provision_and_report
  print_hardening_summary
  warn_datacenter_firewall

  echo "sandbox ready."
  print_ssh_line "$ip"
}

cmd_down() {
  lock_or_die
  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  validate_hardening_config
  work_guard down || die "work guard: refusing to park CT $CTID"
  park_sandbox
  echo "$AGENT sandbox parked: disk clobbered (CLOBBER=$CLOBBER), fresh stub at CT $CTID."
  echo "  right-click Start in the Proxmox GUI, or run '$0 up $AGENT', for the next session."
}

cmd_purge() {
  lock_or_die
  work_guard purge || die "work guard: refusing to purge CT $CTID"
  ct_running && pct stop "$CTID"
  destroy_sandbox
  remove_firewall
  echo "CT $CTID ($AGENT) removed entirely (no stub left in the tree)."
}

# Desktop bundle: copy the managed keypair + an ssh-config snippet +
# per-OS instructions, so the sandbox can be used from a desktop (Windows
# or Linux) instead of the PVE console. The keypair is permanent, so one
# export unlocks every future rebuild; only the embedded IP may go stale
# per rebuild — unless a DHCP reservation pins it (the MAC is retained
# across rebuilds, so one reservation holds forever).
# Honest cost: the private key then also exists in $EXPORT_DIR and on the
# desktop — delete the export dir after fetching the tarball.
cmd_export() {
  lock_or_die
  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  ct_running || die "sandbox not running; run 'up' first (export embeds the current IP)"
  [ -n "$SSH_KEY_FILE" ] || die "export needs the managed keypair; SSH_PUBKEY-override keys live outside this script"
  local ip mac hostip
  ip="$(sandbox_ip)"
  [ -n "$ip" ] || die "no IP for the sandbox (check ${BRIDGE}/DHCP)"
  mac="$(pct config "$CTID" | awk -F'[,=]' '/^net0:/ {for (i=1;i<=NF;i++) if ($i=="hwaddr") print $(i+1)}')"
  hostip="${HOST_IP:-$(hostname -I | awk '{print $1}')}"

  mkdir -p "$EXPORT_DIR"
  chmod 700 "$EXPORT_DIR"
  cp "$SSH_KEY_FILE" "$EXPORT_DIR/ai-sandbox"
  cp "${SSH_KEY_FILE}.pub" "$EXPORT_DIR/ai-sandbox.pub"
  chmod 600 "$EXPORT_DIR/ai-sandbox"
  chmod 644 "$EXPORT_DIR/ai-sandbox.pub"

  cat > "$EXPORT_DIR/ssh-config" <<EOF
# ${CTHOST} — append to ~/.ssh/config (Linux/macOS)
# or %USERPROFILE%\.ssh\config (Windows). HostName goes stale after each
# rebuild UNLESS you set a DHCP reservation for the sandbox MAC (see
# README.txt) — the MAC is permanent, so the reservation holds forever.
Host ${CTHOST}
    HostName $ip
    User root
    IdentityFile ~/.ssh/ai-sandbox
    # disposable sandbox: every rebuild mints a FRESH host key, so
    # strict known-hosts checking would block the 2nd+ rebuild connect.
    # Scoped to this Host alias only — never copy it to other hosts.
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

  cat > "$EXPORT_DIR/README.txt" <<EOF
${CTHOST} desktop bundle (exported $(date '+%Y-%m-%d %H:%M'), CT $CTID)
======================================================================

Use the sandbox from your desktop instead of the Proxmox console.

Contents:
  ai-sandbox        private key (copy of the host-managed sandbox keypair)
  ai-sandbox.pub      public key
  ssh-config          ssh config snippet -> 'ssh ${CTHOST}'
  README.txt          this file

The keypair is permanent and shared by every ai-sandbox agent instance:
one export unlocks every future rebuild; exports for other agents only
add their own Host block to ssh-config.

FIX THE IP (recommended)
------------------------
  The sandbox MAC is also permanent - retained on the host across
  rebuilds - so reserve the IP for it on your DHCP server (router,
  pfSense/OPNsense, Pi-hole, whatever hands out addresses):
    ${mac:-unknown}
  With that reservation, the IP below never goes stale and 'ssh
  ${CTHOST}' just works after every rebuild. Without it, only the
  HostName (IP) goes stale per rebuild - re-run 'export' on the host and
  re-fetch, or edit the HostName line in your ssh config.

Current sandbox IP: $ip

Linux / macOS
-------------
  mkdir -p ~/.ssh && chmod 700 ~/.ssh
  cp ai-sandbox ai-sandbox.pub ~/.ssh/
  cat ssh-config >> ~/.ssh/config
  ssh ${CTHOST}

Windows 10+ (built-in OpenSSH; PowerShell or CMD)
-------------------------------------------------
  if not exist "%USERPROFILE%\.ssh" mkdir "%USERPROFILE%\.ssh"
  copy ai-sandbox "%USERPROFILE%\.ssh\ai-sandbox"
  copy ai-sandbox.pub "%USERPROFILE%\.ssh\ai-sandbox.pub"
  type ssh-config >> "%USERPROFILE%\.ssh\config"
  ssh ${CTHOST}

  (no 'ssh' command? Settings > Apps > Optional features > OpenSSH Client,
  then reopen the terminal)

REBUILDS AND HOST KEYS
----------------------
  Every rebuild mints a fresh SSH host key for the sandbox. The bundled
  ssh-config pins StrictHostKeyChecking no + UserKnownHostsFile /dev/null
  for this one Host, so 'ssh ${CTHOST}' just works after every rebuild.
  (Windows OpenSSH maps /dev/null to NUL; if your ssh rejects the line,
  write NUL there instead.) With a hand-rolled config, expect REMOTE HOST
  IDENTIFICATION HAS CHANGED after each rebuild - expected rotation,
  not an attack; recover and reconnect:
    ssh-keygen -R $ip

PuTTY instead of OpenSSH
------------------------
  puttygen "%USERPROFILE%\.ssh\ai-sandbox" -o ai-sandbox.ppk
  Host Name: $ip   Port: 22   User: root
  (load ai-sandbox.ppk under Connection > SSH > Auth > Credentials)
  (each rebuild mints a fresh host key - accept it when PuTTY asks)

Security
--------
  The private key now also lives on this desktop. It is a dedicated
  sandbox keypair - it unlocks every ai-sandbox instance (every future
  rebuild too), not the Proxmox host. After fetching the tarball, delete the host-side
  copy so the key lives only on host and desktop:
    rm -rf $EXPORT_DIR
EOF

  tar -czf "$EXPORT_DIR/ai-sandbox-${AGENT}-desktop.tar.gz" \
      -C "$EXPORT_DIR" ai-sandbox ai-sandbox.pub ssh-config README.txt
  chmod 600 "$EXPORT_DIR/ai-sandbox-${AGENT}-desktop.tar.gz"

  echo "desktop bundle written to $EXPORT_DIR"
  echo "  fetch from your desktop (host SSH must be reachable from your LAN):"
  echo "    scp root@${hostip}:$EXPORT_DIR/ai-sandbox-${AGENT}-desktop.tar.gz ."
  if [ "$(hostname -I | wc -w)" -gt 1 ]; then
    echo "  note: this host is multi-homed ($(hostname -I | awk '{$1=$1};1')) -"
    echo "  if $hostip is not reachable from your desktop, rerun with:"
    echo "    HOST_IP=<reachable-address> $0 export $AGENT"
  fi
  echo "  then follow the README.txt inside; connect with: ssh ${CTHOST}"
  echo "recommended: set a DHCP reservation for the sandbox MAC ${mac:-unknown} -"
  echo "  it is retained across rebuilds, so the IP stays stable forever"
  echo "note: without a reservation, re-run 'export' after each rebuild - only the IP changes; the key is permanent"
  echo "note: rebuilds mint a fresh host key; the bundled ssh-config pins"
  echo "  StrictHostKeyChecking no for the sandbox Host, so desktop connects survive rebuilds"
  if [ -n "${PROFILE_VSCODE_EXT:-}" ]; then
    echo "VS Code Remote-SSH: add the $PROFILE_LABEL extension to your desktop settings.json"
    echo "  so it installs itself on every connect: \"remote.SSH.defaultExtensions\": [\"$PROFILE_VSCODE_EXT\"]"
  fi
}

# Map a hookscript vmid back to its agent instance. The hook shim is shared
# by every instance and PVE runs it WITHOUT the caller's environment, so the
# CT's own hostname (ai-sandbox-<agent>) is the source of truth; settings
# come from the config files. Not ours -> empty, and the hook does nothing.
hook_agent_for() {   # $1 = vmid; echoes agent or nothing
  local host agent
  host="$(pct config "$1" 2>/dev/null | awk '/^hostname:/ {print $2}')" || return 0
  agent="${host#ai-sandbox-}"
  [ "$agent" != "$host" ] && profile_exists "$agent" && echo "$agent"
  return 0
}

# INTERNAL: entry point for the PVE hookscript shim. PVE calls the shim with
# (vmid, phase); the shim execs this. Phases:
#   pre-start  — allow the boot only if the CT is a pristine stub (see
#                mark_stub_pristine); otherwise abort the Start
#   post-start — wait for IP, provision, log the ssh line
#   pre-stop   — work guard: refuse stops that would lose unextracted work
#   post-stop  — clobber + park stub
# All destructive phases go through guard_ct(): if the CT at $CTID is not
# provably ours, the hook ABORTS the GUI task instead of touching it.
# Hook phases lock with hook_lock(), never lock_or_die: a phase can fire
# from inside `up`'s or `down`'s own pct call, which already holds that
# agent's lock. Lock free -> standalone/GUI task, this hook does the
# phase's work; lock held -> the holder is the triggering operation and
# does the work itself, this hook passes through with exit 0. Locks are
# per agent, so another agent's build never makes this one pass through.
cmd_hook() {
  local vmid="${1:-}" phase="${2:-}" agent
  [[ "$vmid" =~ ^[0-9]+$ ]] || exit 0
  agent="$(hook_agent_for "$vmid")"
  [ -n "$agent" ] || exit 0
  CTID="$vmid"
  select_agent "$agent"
  case "$phase" in
    pre-start)
      # Runs INSIDE Proxmox's Start task, under the CT's config lock: no
      # pct destroy/create/set on this CT from here (they would time out
      # on that lock). Boot only a pristine stub left by down / GUI Stop;
      # anything else aborts the Start (non-zero exit) with directions.
      self_check hook "$vmid" "$phase"
      hook_lock "$phase" || exit 0
      validate_hardening_config
      guard_ct
      stub_is_pristine || die "pre-start: CT $CTID is not a fresh stub (it has booted since it was built, or was not parked by 'down' / GUI Stop). GUI Start cannot rebuild it, because Proxmox holds the CT's lock during Start. On the host, run: $0 up $AGENT"
      stub_firewall_consistent || die "pre-start: firewall settings changed since CT $CTID was parked (FIREWALL=$FIREWALL, EGRESS_POLICY=$EGRESS_POLICY). On the host, run: $0 up $AGENT"
      configure_firewall   # refresh the host-side ruleset (a file under /etc/pve/firewall, not the CT config)
      clear_stub_marker    # booting now: from here on this is a used disk
      echo "pre-start: CT $CTID is a fresh, never-booted stub - starting it"
      ;;  # PVE now boots the stub; post-start provisions it
    post-start)
      hook_lock "$phase" || exit 0
      guard_ct
      local ip
      ip="$(wait_for_ip)" || { echo "post-start: no IP (check ${BRIDGE}/DHCP)"; exit 0; }
      purge_known_hosts "$ip"
      provision_and_report
      print_hardening_summary
      warn_datacenter_firewall
      echo "$AGENT sandbox ready via GUI."
      print_ssh_line "$ip"
      ;;
    pre-stop)
      # Last moment the sandbox is alive: GUI Stop/Restart cannot
      # prompt, so findings abort the stop (PVE aborts the action when a
      # hookscript exits non-zero) unless a CLI guard pass was stamped
      # moments ago. Read-only; never blocks a clean sandbox.
      work_guard pre-stop || die "work guard: refusing to stop CT $CTID with unextracted work"
      ;;
    post-stop)
      hook_lock "$phase" || exit 0
      park_sandbox
      echo "post-stop: $AGENT sandbox clobbered and parked as a fresh stub (CT $CTID)"
      ;;
    *)
      exit 0 ;;
  esac
}

cmd_status() {
  local fw_file="${FW_DIR}/${CTID}.fw" fw_info="none"
  if [ -f "$fw_file" ]; then
    local pol
    pol="$(sed -n 's/.*EGRESS_POLICY=\([^)]*\)).*/\1/p' "$fw_file" | head -n 1)"
    if datacenter_firewall_enabled; then
      fw_info="${pol:-custom} (enforced)"
    else
      fw_info="${pol:-custom} (Datacenter firewall OFF)"
    fi
  fi
  if ! ct_exists; then echo "$AGENT: no sandbox (CT $CTID absent)"; exit 0; fi
  if ct_running; then
    echo "$AGENT: CT $CTID running, ip: $(sandbox_ip), firewall: ${fw_info}"
  else
    if stub_is_pristine; then
      echo "$AGENT: CT $CTID stopped: fresh stub, ready for GUI Start, firewall: ${fw_info}"
    else
      echo "$AGENT: CT $CTID stopped: NOT a fresh stub (GUI Start will refuse; run '$0 up $AGENT'), firewall: ${fw_info}"
    fi
  fi
}

# Every ai-sandbox CT on this node, whichever agent and CTID.
cmd_status_all() {
  local vmid host state ip found=0
  printf '%-10s %-6s %-8s %s\n' AGENT CTID STATE IP
  for vmid in $(pct list 2>/dev/null | awk 'NR>1 {print $1}'); do
    host="$(pct config "$vmid" 2>/dev/null | awk '/^hostname:/ {print $2}')"
    case "$host" in ai-sandbox-?*) ;; *) continue ;; esac
    found=1
    state="$(pct status "$vmid" 2>/dev/null | awk '{print $2}')"
    ip=""
    [ "$state" = "running" ] && ip="$(pct exec "$vmid" -- sh -c 'hostname -I 2>/dev/null | cut -d" " -f1' 2>/dev/null || true)"
    printf '%-10s %-6s %-8s %s\n' "${host#ai-sandbox-}" "$vmid" "${state:-?}" "${ip:--}"
  done
  [ "$found" = 1 ] || echo "(no ai-sandbox CTs on this node)"
}

cmd_agents() {
  local a
  for a in $(list_profiles); do
    ( "profile_${a}_meta"; printf '%-10s CT %-6s %s\n' "$a" "$PROFILE_CTID" "$PROFILE_LABEL" )
  done
}

cmd_shell() {
  ct_running || die "$AGENT sandbox not running; run '$0 up $AGENT' first"
  pct enter "$CTID"
}

# Manual self-update: install main's copy explicitly. Works regardless of
# AUTO_UPDATE; never re-execs. cmp against the current file first so a
# no-op is quiet.
cmd_update() {
  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  local self tmp bak
  self="$(readlink -f "$0")"
  tmp="$(mktemp)" || die "mktemp failed"
  fetch_current_script "$tmp" 60 || die "could not fetch/validate $RAW_URL"
  if cmp -s "$self" "$tmp"; then
    rm -f "$tmp"
    echo "script already current: $self"
    return 0
  fi
  bak="$(install_current_script "$tmp")"
  echo "updated $self from main (previous copy: $bak)"
}

# --------------------------- dispatch ---------------------------------------
cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  up|down|purge|reset|shell|ip|export) select_agent "${1:-}" ;;
  status) [ -z "${1:-${AGENT:-}}" ] || select_agent "${1:-}" ;;
esac
case "$cmd" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  purge)  cmd_purge ;;
  reset)  cmd_down; cmd_up ;;
  status) if [ -n "${AGENT:-}" ]; then cmd_status; else cmd_status_all; fi ;;
  ip)     sandbox_ip ;;
  shell)  cmd_shell ;;
  export) cmd_export ;;
  agents) cmd_agents ;;
  update) cmd_update ;;
  hook)   cmd_hook "$@" ;;
  *) awk '/^set -/ {exit} /^#/ {print}' "$0"; exit 1 ;;
esac

# --------------------------- usage patterns (optional) -----------------------
# Rebuild a sandbox on every host boot (even if a stale CT survived a crash):
# save as /etc/cron.d/ai-sandbox
#
#   @reboot root /root/ai-sandbox.sh up mistral >> /var/log/ai-sandbox.log 2>&1
#
# Or an on-demand session (recommended for single-use): `up` before the
# agent starts, `down` after review:
#
#   ai-sandbox.sh up claude && ssh -i /root/.ai-sandbox/ssh/ai-sandbox root@$(ai-sandbox.sh ip claude) ; ai-sandbox.sh down claude

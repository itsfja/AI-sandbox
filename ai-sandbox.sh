#!/usr/bin/env bash
# ============================================================================
# ai-sandbox.sh — single-use, rebuild-on-demand LXC sandboxes for AI coding
#                 agents on Proxmox VE (Mistral Vibe, Claude Code, Gemini CLI,
#                 and any other agent as a drop-in profile)
#
# Usage:  ai-sandbox.sh <command> [agent]        (or AGENT=<agent> in env)
#
#   up      <agent>  rebuild + start + provision + print SSH line
#   down    <agent>  clobber disk + park a fresh stopped stub (GUI Start-able)
#   purge   <agent>  destroy completely — no stub, gone from the tree
#   reset   <agent>  down then up (fresh rebuild mid-work)
#   status  [agent]  one sandbox, or every ai-sandbox CT when no agent given
#   ssh     <agent> [cmd]  ssh in with the managed key (or run cmd)
#   shell   <agent>  root shell inside the CT (pct enter)
#   ip      <agent>  current IP (empty if not running)
#   export  <agent>  desktop bundle: keypair + ssh-config (after 'up')
#   agents           list the agent profiles this script knows
#   bake             build a golden template (every agent CLI) in a free slot;
#                    sessions then start as linked clones of it (MODE)
#   timer [on|off]   weekly `bake` via a systemd timer (BAKE_SCHEDULE); no
#                    argument shows its schedule, next run and last result
#   refresh-stub     INTERNAL — re-park a pristine stub onto the new golden
#   update           self-update from main (previous copy kept as .bak)
#   hook             INTERNAL — called by the PVE hookscript shim (vmid, phase)
#   park-deferred    INTERNAL — run by systemd after a GUI Stop (agent, vmid)
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
#   <agent>/pristine-stub    "the stopped CT has never booted" (GUI Start gate)
#   <agent>/provisioned      "the running CT finished provisioning" (status)
#   golden/current           CTID of the current golden template (after `bake`)
#   golden/stamp             when it was baked, for which agents, CLI versions
# config.env files hold plain KEY=value lines (never executed). Precedence:
# command-line env > <agent>/config.env > config.env > built-in default.
# Put lasting overrides there: GUI Start/Stop hooks run WITHOUT your shell
# environment, so only the config files reach them.
#
# Design invariants (carried over from mistral-sandbox; README has detail):
#   SINGLE USE      nothing persists between sessions; `up` never resumes
#   GUI-TRAPPED     PVE hookscript: Stop = clobber + fresh stub (a systemd
#                   job, once the Stop task has released the CT), Start =
#                   boot that never-booted stub and provision it. Restart
#                   is unsupported: use Stop, then Start
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
PROFILES_DIR="${STATE_DIR}/profiles"   # drop-in agent profiles: <agent>.sh

die() { echo "error: $*" >&2; exit 1; }

# Files this script reads (config.env) or sources (drop-in profiles) run with
# root's authority, so only root may be able to change them.
require_root_safe() {   # $1 = path
  [ "$(stat -c %u "$1")" = "0" ] || die "refusing $1: not owned by root"
  case "$(stat -c %a "$1")" in
    *[2367]?|*?[2367]) die "refusing $1: group/other-writable" ;;
  esac
}

# Read KEY=value lines from a config file WITHOUT executing it. A key already
# set in the environment wins, so command-line overrides beat the file; the
# first file loaded wins over later ones (load the most specific first).
load_config_file() {   # $1 = path
  local file="$1" line key val
  [ -f "$file" ] || return 0
  require_root_safe "$file"
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
# "golden" is reserved: the baked template is CT hostname ai-sandbox-golden
profile_exists()   { valid_agent_name "$1" && [ "$1" != golden ] && declare -F "profile_${1}_meta" >/dev/null; }

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

# --------------------------- drop-in profiles (#12) --------------------------
# $PROFILES_DIR/<agent>.sh adds an agent without editing this script. It is
# SOURCED as root on every run (hooks included), so it is held to more than
# config.env: the directory and file root-owned and not group/other-
# writable, no symlinks, a valid unused agent name, every required part,
# a CTID no other profile uses, and it may only ADD functions named
# profile_<agent>_*: one that redefines any existing function (a built-in
# profile's, or the script's own, e.g. guard_ct) or changes the script's
# paths is refused, and with it the whole run (fail closed).
DROPIN_GUARDED_VARS=(STATE_DIR PROFILES_DIR FW_DIR PVE_LXC_DIR SYSTEMD_UNIT_DIR SANDBOX_TAG HOOK_VOL_ID HOOK_SNIPPET_DIR PATH)
PROFILE_PARTS=(meta install verify credentials policy credential_paths)

load_dropin_profiles() {
  local dir="$PROFILES_DIR" f name fns dump_before dump_after vars_before fn part bad=""
  [ -e "$dir" ] || return 0
  [ ! -L "$dir" ] || die "refusing drop-in profiles: $dir is a symlink"
  [ -d "$dir" ] || die "refusing drop-in profiles: $dir is not a directory"
  require_root_safe "$dir"
  for f in "$dir"/*.sh; do
    [ -e "$f" ] || continue
    name="${f##*/}"
    name="${name%.sh}"
    [ ! -L "$f" ] || die "refusing drop-in profile $f: a symlink"
    [ -f "$f" ] || die "refusing drop-in profile $f: not a regular file"
    require_root_safe "$f"
    { valid_agent_name "$name" && [ "$name" != golden ]; } \
      || die "refusing drop-in profile $f: '$name' is not a valid agent name (a lowercase letter, then up to 15 lowercase letters or digits; 'golden' is reserved)"
    ! declare -F "profile_${name}_meta" >/dev/null \
      || die "refusing drop-in profile $f: agent '$name' already exists (built-in)"
    read -r -a fns <<<"$(declare -F | awk '{print $3}' | paste -sd' ' -)"
    dump_before="$(declare -f "${fns[@]}")"
    vars_before="$(for v in "${DROPIN_GUARDED_VARS[@]}"; do printf '%s=%s\n' "$v" "${!v-}"; done)"
    # shellcheck source=/dev/null
    source "$f"
    dump_after="$(declare -f "${fns[@]}")"
    if [ "$dump_after" != "$dump_before" ]; then
      for fn in "${fns[@]}"; do
        [ "$(declare -f "$fn")" = "$(sed -n "/^$fn () $/,/^}$/p" <<<"$dump_before")" ] || bad="$bad $fn"
      done
      die "refusing drop-in profile $f: it redefines existing function(s):${bad:- (unknown)}"
    fi
    [ "$(for v in "${DROPIN_GUARDED_VARS[@]}"; do printf '%s=%s\n' "$v" "${!v-}"; done)" = "$vars_before" ] \
      || die "refusing drop-in profile $f: it changes the script's own settings (one of ${DROPIN_GUARDED_VARS[*]})"
    for fn in $(declare -F | awk '{print $3}'); do
      [[ " ${fns[*]} " == *" $fn "* ]] && continue
      [[ "$fn" == "profile_${name}_"* ]] \
        || die "refusing drop-in profile $f: it defines '$fn'; a drop-in may only define profile_${name}_* functions"
    done
    for part in "${PROFILE_PARTS[@]}"; do
      declare -F "profile_${name}_${part}" >/dev/null \
        || die "refusing drop-in profile $f: no profile_${name}_${part} (required: ${PROFILE_PARTS[*]})"
    done
  done
  check_profile_ctids
}

# Two agents on one CTID would fight over a container; refuse up front.
check_profile_ctids() {
  local a id seen=" " owner
  for a in $(list_profiles); do
    id="$( "profile_${a}_meta"; echo "${PROFILE_CTID:-}" )"
    [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -ge 100 ] \
      || die "profile '$a': PROFILE_CTID '${id}' is not a CT ID (100 or more)"
    owner="$(sed -n "s/.* $id=\([a-z0-9]*\) .*/\1/p" <<<"$seen")"
    [ -z "$owner" ] || die "profiles '$owner' and '$a' both use CT $id; give one a different PROFILE_CTID"
    seen="$seen$id=$a "
  done
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
PVE_LXC_DIR="${PVE_LXC_DIR:-/etc/pve/lxc}"  # this node's CT configs (read directly; see ct_conf)
SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"   # where `timer on` writes its units
BAKE_UNIT="ai-sandbox-bake"
UNIT_MARKER="# Managed by ai-sandbox.sh (timer on/off) - edits are overwritten"

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
  PROVISIONED_MARKER="${INSTANCE_DIR}/provisioned"  # "this running CT finished provisioning"
  PARK_UNIT="ai-sandbox-park-${AGENT}-${CTID}"  # transient systemd unit that parks after a GUI Stop
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
  EGRESS_DENY="${EGRESS_DENY:-}"       # extra CIDRs lan-block drops: your site's PUBLIC IPv6 range(s)
  MODE="${MODE:-auto}"                 # auto | clone | rebuild - how sessions are built (see spawn_mode)
  TOPUP="${TOPUP:-off}"                # on = re-run the agent's CLI installer on a clone at spawn
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
#   credential_paths   print the in-CT paths the credential lands at, one per
#                 line; `bake` fails if any of them exists in the golden image
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

profile_mistral_credential_paths() { echo /root/.vibe/.env; }

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

# ---- claude: Claude Code ------------------------------------------------------
profile_claude_meta() {
  PROFILE_CTID=1052
  PROFILE_LABEL="Claude Code"
  PROFILE_VSCODE_EXT="anthropic.claude-code"
}

# Native installer: one binary, no Node; the launcher is ~/.local/bin/claude.
# Native installs also update themselves in the background, so a clone's
# Claude Code is at least as new as the bake, usually newer.
profile_claude_install() {
  cat <<'EOF'
curl -fsSL https://claude.ai/install.sh | bash
ln -sf /root/.local/bin/claude /usr/local/bin/claude 2>/dev/null || true
EOF
}

profile_claude_verify() { echo "claude --version"; }

# secrets.env holds ONE of (parsed here, never executed):
#   ANTHROPIC_API_KEY=sk-ant-api...       a Claude Console API key
#   CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat... a subscription token from `claude
#                                         setup-token` (Pro/Max/Team/Enterprise,
#                                         valid one year, model requests only)
# It reaches Claude Code through the `env` block of the user settings file,
# which the CLI and the VS Code extension both read.
profile_claude_credentials() {
  local api oauth tmp key val
  api="$(secrets_get ANTHROPIC_API_KEY "$SECRETS_FILE")"
  oauth="$(secrets_get CLAUDE_CODE_OAUTH_TOKEN "$SECRETS_FILE")"
  [ -n "$api" ] || [ -n "$oauth" ] \
    || die "no ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN line in $SECRETS_FILE"
  if [ -n "$api" ] && [ -n "$oauth" ]; then
    echo "warning: $SECRETS_FILE sets both; Claude Code uses ANTHROPIC_API_KEY first" >&2
  fi
  for key in ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN; do
    val="$(secrets_get "$key" "$SECRETS_FILE")"
    [ -z "$val" ] || [[ "$val" =~ ^[A-Za-z0-9_.-]+$ ]] \
      || die "$key in $SECRETS_FILE has characters a key or token never contains"
  done
  tmp="$(mktemp)"
  {
    printf '{\n  "env": {'
    [ -n "$api" ] && printf '\n    "ANTHROPIC_API_KEY": "%s"%s' "$api" "$([ -n "$oauth" ] && echo ,)"
    [ -n "$oauth" ] && printf '\n    "CLAUDE_CODE_OAUTH_TOKEN": "%s"' "$oauth"
    printf '\n  }\n}\n'
  } > "$tmp"
  ct_push_file "$tmp" /root/.claude/settings.json 600 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  echo "credentials injected (host: $SECRETS_FILE -> CT: /root/.claude/settings.json env)"
}

profile_claude_credential_paths() { echo /root/.claude/settings.json; }

profile_claude_credentials_hint() {
  echo "  either a Claude Console API key:"
  echo "    printf 'ANTHROPIC_API_KEY=<key>\\n' > $SECRETS_FILE && chmod 600 $SECRETS_FILE"
  echo "  or your subscription: run 'claude setup-token' anywhere with a browser, then:"
  echo "    printf 'CLAUDE_CODE_OAUTH_TOKEN=<token>\\n' > $SECRETS_FILE && chmod 600 $SECRETS_FILE"
}

# Managed settings outrank every user/project/--settings value in the CT.
profile_claude_policy() {
  local tmp parts=()
  [ "$AGENT_AUTO_APPROVE" = on ] || parts+=('"permissions": { "disableBypassPermissionsMode": "disable" }' '"disableAutoMode": "disable"')
  [ "$AGENT_CONNECTORS" = on ] || parts+=('"disableClaudeAiConnectors": true')
  [ "$AGENT_MCP" = on ] || parts+=('"allowedMcpServers": []' '"enableAllProjectMcpServers": false')
  tmp="$(mktemp)"
  {
    echo "{"
    local i
    for i in "${!parts[@]}"; do
      printf '  %s%s\n' "${parts[$i]}" "$([ "$i" -lt $((${#parts[@]} - 1)) ] && echo ,)"
    done
    echo "}"
  } > "$tmp"
  ct_push_file "$tmp" /etc/claude-code/managed-settings.json 444 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  echo "hardening: injected /etc/claude-code/managed-settings.json"
}

# ---- gemini: Gemini CLI --------------------------------------------------------
profile_gemini_meta() {
  PROFILE_CTID=1053
  PROFILE_LABEL="Gemini CLI"
  PROFILE_VSCODE_EXT="google.gemini-cli-vscode-ide-companion"
}

# Gemini CLI is an npm package needing Node.js >= 20; Debian 12 ships 18,
# so Node 22 LTS comes from NodeSource (same trust model as the other
# agents' curl | bash installers). It lands in the golden for every agent.
profile_gemini_install() {
  cat <<'EOF'
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq --no-install-recommends -o Dpkg::Use-Pty=0 nodejs
fi
npm install -g --no-fund --no-audit @google/gemini-cli
# Gemini CLI loads no .env file in a folder it does not trust, not even
# ~/.gemini/.env (seen on pve1: "must specify GEMINI_API_KEY"). Folder
# trust stays on; this launcher, first on PATH, reads the sandbox's own key
# file, never a project's, then runs the real CLI.
real="$(command -v gemini)"
if [ "$real" != /usr/local/bin/gemini ]; then
  printf '%s\n' '#!/bin/sh' \
    '# ai-sandbox: GEMINI_API_KEY from ~/.gemini/.env, also in untrusted folders' \
    'if [ -z "${GEMINI_API_KEY:-}" ] && [ -r "${HOME:-/root}/.gemini/.env" ]; then' \
    '  GEMINI_API_KEY="$(sed -n "s/^GEMINI_API_KEY=//p" "${HOME:-/root}/.gemini/.env" | tail -n 1)"' \
    '  export GEMINI_API_KEY' \
    'fi' \
    "exec $real \"\$@\"" > /usr/local/bin/gemini
  chmod 755 /usr/local/bin/gemini
fi
EOF
}

profile_gemini_verify() { echo "gemini --version"; }

# secrets.env holds GEMINI_API_KEY=<key> (Google AI Studio). It is parsed,
# never executed, and written to ~/.gemini/.env, which the CLI loads unless
# a project has its own .env (the first .env found wins). The user settings
# select API-key auth so the first run does not ask how to sign in.
profile_gemini_credentials() {
  local key tmp
  key="$(secrets_get GEMINI_API_KEY "$SECRETS_FILE")"
  [ -n "$key" ] || die "no GEMINI_API_KEY line in $SECRETS_FILE"
  [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || die "GEMINI_API_KEY in $SECRETS_FILE has characters a key never contains"
  tmp="$(mktemp)"
  printf 'GEMINI_API_KEY=%s\n' "$key" > "$tmp"
  ct_push_file "$tmp" /root/.gemini/.env 600 || { rm -f "$tmp"; return 1; }
  printf '{\n  "security": { "auth": { "selectedType": "gemini-api-key" } }\n}\n' > "$tmp"
  ct_push_file "$tmp" /root/.gemini/settings.json 600 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  echo "credentials injected (host: $SECRETS_FILE -> CT: /root/.gemini/.env)"
}

profile_gemini_credential_paths() { echo /root/.gemini/.env; }

profile_gemini_credentials_hint() {
  echo "  create a key at aistudio.google.com (Get API key), then run:"
  echo "    printf 'GEMINI_API_KEY=<key>\\n' > $SECRETS_FILE && chmod 600 $SECRETS_FILE"
}

# The system settings file overrides user and project settings.
#   AGENT_AUTO_APPROVE  YOLO mode and "Always allow" (security.* and the
#                       admin secure mode)
#   AGENT_MCP           MCP servers (empty allowlist + admin switch)
#   AGENT_CONNECTORS    extensions, Gemini's add-on mechanism (they can
#                       bundle MCP servers and tools)
profile_gemini_policy() {
  local tmp sec=() adm=() top=() all=() i
  if [ "$AGENT_AUTO_APPROVE" != on ]; then
    sec+=('"disableYoloMode": true' '"disableAlwaysAllow": true')
    adm+=('"secureModeEnabled": true')
  fi
  if [ "$AGENT_MCP" != on ]; then
    top+=('"mcp": { "allowed": [] }')
    adm+=('"mcp": { "enabled": false }')
  fi
  if [ "$AGENT_CONNECTORS" != on ]; then
    sec+=('"blockGitExtensions": true')
    adm+=('"extensions": { "enabled": false }')
  fi
  [ "${#sec[@]}" -gt 0 ] && all+=("\"security\": { $(IFS=,; echo "${sec[*]}" | sed 's/,/, /g') }")
  [ "${#adm[@]}" -gt 0 ] && all+=("\"admin\": { $(IFS=,; echo "${adm[*]}" | sed 's/,/, /g') }")
  all+=("${top[@]}")
  tmp="$(mktemp)"
  {
    echo "{"
    for i in "${!all[@]}"; do
      printf '  %s%s\n' "${all[$i]}" "$([ "$i" -lt $((${#all[@]} - 1)) ] && echo ,)"
    done
    echo "}"
  } > "$tmp"
  ct_push_file "$tmp" /etc/gemini-cli/settings.json 444 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  echo "hardening: injected /etc/gemini-cli/settings.json"
}

# One KEY=value from a secrets file, parsed like the config files (never
# executed; one pair of surrounding quotes stripped). Empty if absent.
secrets_get() {   # $1 = key, $2 = file
  local line val
  [ -f "$2" ] || return 0
  line="$(grep -E "^[[:space:]]*(export[[:space:]]+)?$1=" "$2" | tail -n1)" || return 0
  val="${line#*=}"
  val="${val%$'\r'}"
  if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then
    val="${BASH_REMATCH[1]}"
  fi
  printf '%s' "$val"
}

# --------------------------- helpers ---------------------------------------

lock_or_die() {
  exec 9>"$LOCK_FILE"
  flock -n 9 && return 0
  park_job_active && die "the $AGENT sandbox is still being parked after a GUI Stop (unit $PARK_UNIT); wait a minute and retry. Progress: journalctl -u $PARK_UNIT"
  die "another ai-sandbox operation is running on the $AGENT sandbox (serial per agent)"
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

# A copy inside a git checkout is updated with `git pull`: self-update
# would rewrite a tracked file and leave a .bak beside it, so a later pull
# conflicts. Detected by a .git entry in the script's directory or above
# (no dependency on git being installed on the host).
script_git_checkout() {   # echoes the checkout root, rc 0 when inside one
  local d
  d="$(dirname "$(readlink -f "$0")")"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -e "$d/.git" ] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

self_check() {   # "$@" = full original argv; installs + re-execs once if stale
  [ "$AUTO_UPDATE" = "on" ] || return 0
  [ -z "${AI_SANDBOX_SELF_UPDATED:-}" ] || return 0
  local repo
  if repo="$(script_git_checkout)"; then
    echo "self-check: skipped - running from the git checkout at $repo (update it with git pull)"
    return 0
  fi
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
ct_run() { ct_attach "$CTID" "${CT_ENV[@]}" "$@"; }

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

# Read-only queries go around `pct`: every pct call loads Proxmox's Perl
# libraries, about 2.5 s each on pve1 (an `up` made ~25 of them). Reads use
# what pct itself uses underneath: the config file, lxc-info, lxc-attach.
# Anything that CHANGES a CT (create/clone/set/start/stop/destroy/template)
# still goes through pct, for Proxmox's locking and bookkeeping.
ct_conf() {   # $1 = CTID; prints its current config (no snapshot/pending sections); rc 1 if absent
  local f="${PVE_LXC_DIR}/${1}.conf"
  [ -f "$f" ] || return 1
  awk '/^\[/ {exit} {print}' "$f"
}

ct_list() {   # CTIDs configured on this node
  local f
  for f in "$PVE_LXC_DIR"/*.conf; do
    [ -e "$f" ] || continue
    f="${f##*/}"; f="${f%.conf}"
    [[ "$f" =~ ^[0-9]+$ ]] && echo "$f"
  done
  return 0
}

ct_id_running() {   # $1 = CTID; lxc's view, as pct status uses (mid-Stop it still runs)
  case "$(lxc-info -n "$1" -sH 2>/dev/null)" in
    ''|STOPPED) return 1 ;;
  esac
  return 0
}

ct_attach() {   # $1 = CTID, then the command; like `pct exec`, minus the Perl start-up
  local id="$1"
  shift
  lxc-attach -n "$id" --clear-env -- "$@"
}

ct_exists()  { [ -f "${PVE_LXC_DIR}/${CTID}.conf" ]; }
ct_running() { ct_id_running "$CTID"; }

sandbox_ip() {
  ct_attach "$CTID" sh -c 'hostname -I 2>/dev/null | cut -d" " -f1' 2>/dev/null || true
}

# Block device of a volume: lvm/lvmthin from storage.cfg's vgname (instant),
# anything else through pvesm (Perl, slow).
volid_dev() {   # $1 = <storage>:<volume>
  local store="${1%%:*}" vol="${1#*:}" vg
  case "$(storage_type "$store")" in
    lvm|lvmthin)
      vg="$(storage_cfg_value "$store" vgname)"
      [ -n "$vg" ] && { echo "/dev/${vg}/${vol}"; return 0; } ;;
  esac
  pvesm path "$1" 2>/dev/null
}

# The Debian template is only needed for a full build (rebuild, bake);
# looking it up costs several pveam (Perl) calls and a network refresh.
ensure_template() {
  [ -n "$TEMPLATE" ] && return 0
  exec 8>"$SHARED_LOCK"
  flock -w 900 8 || die "timed out waiting for shared setup lock $SHARED_LOCK"
  TEMPLATE="$(template_auto)"
  flock -u 8
  exec 8>&-
}

wait_for_ip() {
  local ip=""
  for _ in $(seq 1 45); do
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
  cfg="$(ct_conf "$CTID")"
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
  clear_provisioned
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
  local var saved_ifs entry
  for var in EGRESS_ALLOW EGRESS_DENY; do
    [ -n "${!var}" ] || continue
    saved_ifs="$IFS"
    IFS=','
    for entry in ${!var}; do
      IFS="$saved_ifs"
      entry="$(printf '%s' "$entry" | tr -d ' \t')"
      [ -n "$entry" ] || continue
      validate_cidr_or_ip "$entry" || die "invalid IP/CIDR '$entry' in $var"
    done
    IFS="$saved_ifs"
  done
}

csv_entries() {   # $1 = comma-separated list; prints one trimmed entry per line
  local saved_ifs="$IFS" entry
  IFS=','
  for entry in $1; do
    IFS="$saved_ifs"
    entry="$(printf '%s' "$entry" | tr -d ' \t')"
    [ -n "$entry" ] && printf '%s\n' "$entry"
  done
  IFS="$saved_ifs"
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

# lan-block's built-in ranges are all private; a sandbox holding a PUBLIC
# IPv6 address can reach your LAN devices' public IPv6 addresses unless
# EGRESS_DENY lists your site's range. Warn when that gap is open.
warn_public_ipv6() {
  [ "$FIREWALL" = "on" ] && [ "$EGRESS_POLICY" = "lan-block" ] || return 0
  [ -z "$EGRESS_DENY" ] || return 0
  local addrs first suggest=""
  addrs="$(ct_run ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | sort -u)"
  [ -n "$addrs" ] || return 0
  first="$(head -n1 <<<"$addrs")"
  [[ "$first" =~ ^([0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}:[0-9a-fA-F]{1,4}): ]] && suggest="${BASH_REMATCH[1]}::/48"
  echo "warning: the $AGENT sandbox has public IPv6 address(es):"
  sed 's/^/    /' <<<"$addrs"
  echo "  lan-block only drops private ranges, so your LAN devices' public IPv6 addresses are reachable."
  echo "  set your site's delegated prefix in ${STATE_DIR}/config.env, e.g.:"
  echo "    EGRESS_DENY=${suggest:-<your ISP-delegated IPv6 prefix>}"
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
    # Your LAN is not only RFC1918: with native IPv6, every device also has
    # a PUBLIC address in the ISP-delegated prefix, which no private-range
    # rule matches. EGRESS_DENY carries that range (e.g. your /48).
    local entry
    while IFS= read -r entry; do
      printf 'OUT DROP -dest %s -log nolog # EGRESS_DENY (site range)\n' "$entry"
    done < <(csv_entries "$EGRESS_DENY")
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
  if firewall_active && ! grep -qsF "$FW_MARKER" "${FW_DIR}/${CTID}.fw"; then
    fw_state="${EGRESS_POLICY} (RULESET MISSING: ${FW_DIR}/${CTID}.fw)"
  elif firewall_active; then
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
  local hookargs=() startargs=() net0_opts golden
  validate_hardening_config
  ensure_mac
  configure_firewall
  net0_opts="name=eth0,bridge=${BRIDGE},ip=dhcp${CT_MAC:+,hwaddr=$CT_MAC}"
  firewall_active && net0_opts="${net0_opts},firewall=1"
  [ "$HOOK" = "on" ] && hookargs=(--hookscript "$HOOK_VOL_ID")
  golden="$(spawn_mode)"
  if [ -n "$golden" ]; then
    clone_sandbox "$golden" "${1:-start}" "$net0_opts" "${hookargs[@]}"
    return 0
  fi
  ensure_template
  echo "full build from $TEMPLATE ..."
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

# --------------------------- spawn from the golden (#9, part 2) ----------------
# MODE decides how a session is built:
#   auto     linked clone of the current golden when one exists and has this
#            agent baked in; otherwise a full rebuild (with a note)
#   clone    linked clone, or refuse (no silent minutes-long rebuild)
#   rebuild  always the full build from the Debian template (pre-bake path)
# A clone inherits the golden's baseline and CLIs; spawn provisioning only
# gives it what is per-session: fresh SSH host keys, root's authorized key,
# the credential, the policy, user hooks (and the CLI again with TOPUP=on).
# Which provisioning runs is decided by what the CT IS (its rootfs is a
# linked clone or not), so the GUI post-start hook, which has no shell
# environment, always matches how the CT was built.

validate_spawn_config() {
  case "$MODE" in auto|clone|rebuild) ;; *) die "invalid MODE='$MODE' (expected 'auto', 'clone' or 'rebuild')" ;; esac
  validate_on_off TOPUP "$TOPUP"
}

golden_usable() {   # $1 = golden CTID; rc 0 when it is a template with $AGENT baked in
  local cfg agents
  cfg="$(ct_conf "$1")" || return 1
  grep -q '^hostname: ai-sandbox-golden$' <<<"$cfg" && grep -q '^template: 1$' <<<"$cfg" || return 1
  agents="$(sed -n 's/.* agents=\([^ ]*\).*/\1/p' "${STATE_DIR}/golden/stamp" 2>/dev/null | head -n1)"
  [[ ",${agents}," == *",${AGENT},"* ]]
}

spawn_mode() {   # echoes the golden CTID to clone from; empty = full rebuild
  validate_spawn_config
  [ "$MODE" = rebuild ] && return 0
  local golden
  golden="$(golden_current)"
  if [ -n "$golden" ] && golden_usable "$golden"; then
    echo "$golden"
    return 0
  fi
  local why="no golden template yet (run '$0 bake')"
  [ -n "$golden" ] && why="golden CT $golden is missing, not a template, or was baked without $AGENT (run '$0 bake')"
  [ "$MODE" = clone ] && die "MODE=clone: $why; or set MODE=rebuild"
  echo "MODE=auto: $why - full rebuild instead" >&2
}

# Linked clone of the golden, then this instance's own settings on top.
clone_sandbox() {   # $1 = golden CTID, $2 = start|stopped, $3 = net0, "${@:4}" = hookscript args
  local golden="$1" mode="$2" net0="$3" size
  shift 3
  echo "cloning CT $CTID from golden CT $golden (linked clone) ..."
  pct clone "$golden" "$CTID" --hostname "$CTHOST" --full 0
  # pct clone replaces the target's firewall file with the source's (it
  # deletes ours, and the golden has none): write this CT's ruleset again
  configure_firewall
  pct set "$CTID" \
    --cores "$CORES" --memory "$RAM_MB" --swap "$SWAP_MB" \
    --net0 "$net0" \
    --tags "$SANDBOX_TAG" \
    --onboot 0 \
    "$@"
  # the clone has the golden's disk size; grow it if this agent wants more
  size="$(ct_conf "$CTID" | sed -n 's/^rootfs: .*size=\([0-9]*\)G.*/\1/p')"
  if [ -n "$size" ] && [ "$DISK_GB" -gt "$size" ]; then
    pct resize "$CTID" rootfs "${DISK_GB}G"
  elif [ -n "$size" ] && [ "$DISK_GB" -lt "$size" ]; then
    echo "note: DISK_GB=$DISK_GB is below the golden's ${size}G; a clone cannot shrink, keeping ${size}G" >&2
  fi
  assert_firewall_in_place
  [ "$mode" = start ] && pct start "$CTID"
  return 0
}

# Which template a CT's rootfs is a linked clone of. The volume ID alone
# does not say on every storage: zfspool/rbd name a clone
# "base-<id>-disk-N/<own volume>", but lvmthin names it plainly
# "vm-<ctid>-disk-N" (seen on pve1); only its LVM origin is the base.
ct_golden_base() {   # $1 = CTID (default $CTID); echoes the template CTID, if any
  local id="${1:-$CTID}" volid dev origin
  volid="$(ct_conf "$id" | sed -n 's/^rootfs: \([^,]*\).*/\1/p' | head -n1)"
  [ -n "$volid" ] || return 0
  if [[ "$volid" =~ :base-([0-9]+)-disk-[0-9]+/ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  dev="$(volid_dev "$volid")" || return 0
  [[ "$dev" == /dev/* ]] || return 0
  origin="$(lvs --noheadings -o origin "$dev" 2>/dev/null | tr -d ' ')"
  [[ "$origin" =~ ^base-([0-9]+)-disk-[0-9]+$ ]] && echo "${BASH_REMATCH[1]}"
  return 0
}

# Fail closed: never start a sandbox whose host-side ruleset is missing.
assert_firewall_in_place() {
  firewall_active || return 0
  local fw="${FW_DIR}/${CTID}.fw"
  [ -f "$fw" ] && grep -qF "$FW_MARKER" "$fw" \
    || die "firewall: managed ruleset $fw is missing - refusing to start an unfiltered sandbox"
}

# Per-session provisioning of a clone (everything else is baked in).
spawn_provision() {
  echo "spawn: fresh SSH host keys, authorized key, credential and policy for $PROFILE_LABEL ..."
  # The golden has no host keys, so on a clone's first boot sshd fails its
  # pre-start check until systemd's start-rate limit trips (seen on pve1:
  # once spawn got fast, the restart came within that window and was
  # refused, silently). Clear the limit, restart, and insist it runs.
  ct_run bash -c 'set -e
ssh-keygen -A >/dev/null
systemctl reset-failed ssh >/dev/null 2>&1 || true
systemctl restart ssh
systemctl is-active --quiet ssh' \
    || die "spawn: sshd did not start in CT $CTID (lxc-attach -n $CTID -- systemctl status ssh)"
  # hooks never run shared_setup, so fall back to the managed key's .pub
  local pub="${SSH_PUBKEY:-${SSH_KEY_FILE}.pub}"
  [ -f "$pub" ] || die "spawn: no SSH public key at $pub (run '$0 up $AGENT' once to generate the keypair)"
  ct_push_file "$pub" /root/.ssh/authorized_keys 600
  if [ "$TOPUP" = on ]; then
    echo "spawn: TOPUP=on - re-running the $PROFILE_LABEL installer for the latest release ..."
    local t
    t="$(mktemp)"
    {
      printf '#!/usr/bin/env bash\nset -euo pipefail\nexport LC_ALL=C PATH="/root/.local/bin:$PATH"\n'
      "profile_${AGENT}_install"
      "profile_${AGENT}_verify"
    } > "$t"
    ct_push_file "$t" /root/topup.sh 700
    rm -f "$t"
    ct_run bash /root/topup.sh
  fi
}

# INTERNAL (run by `bake`): a pristine stub still on an older golden, or on
# a full build, is re-parked onto the new golden: a stub holds nothing, and
# moving it frees the old golden slot for the next bake.
cmd_refresh_stub() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || { echo "refresh: $AGENT is busy - its stub moves at its next park"; return 0; }
  stub_is_pristine || return 0
  local cur base
  cur="$(golden_current)"
  base="$(ct_golden_base)"
  [ -n "$cur" ] && [ "$base" != "$cur" ] || return 0
  golden_usable "$cur" || return 0
  validate_hardening_config
  echo "refresh: re-parking the $AGENT stub (CT $CTID) onto golden CT $cur ..."
  park_sandbox
}

# Wipe the rootfs of the STOPPED CT (keep the disk object, destroy the data).
clobber_disk() {
  [ "$CLOBBER" = "off" ] && return 0
  guard_ct   # ownership interlock: never wipe a CT that is not ours
  local line volid dev
  line="$(ct_conf "$CTID" | awk '/^rootfs:/')" || true
  volid="$(echo "$line" | cut -d' ' -f2 | cut -d, -f1)"
  [ -n "$volid" ] || { echo "clobber: no rootfs volid found, skipping"; return 0; }
  dev="$(volid_dev "$volid" || true)"
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

# GUI Stop cannot park in its own post-stop hook either: Proxmox keeps the
# CT's config lock for the whole Stop task, the task does not end until the
# post-stop hook has returned, and `pct status` still says "running"
# meanwhile. Any pct stop/destroy/create from the hook times out on that
# lock (seen on pve1 as a second "CT <id> - Stop" task failing). So
# post-stop only hands the park to a transient systemd unit ($PARK_UNIT,
# one per agent instance) and returns; the unit waits until PVE has
# finished the Stop (pve-container@<CTID> inactive, lock released), takes
# the agent's serial lock, re-checks, then parks. systemd-run, not
# `cmd &`: a background child of the hook sits in the container's cgroup
# and is killed with it.
# "activating" counts: post-stop schedules with --no-block, and a GUI
# Restart's pre-start can arrive before the unit is fully up.
park_job_active() {
  case "$(systemctl is-active "$PARK_UNIT" 2>/dev/null)" in
    active|activating|reloading) return 0 ;;
  esac
  return 1
}

schedule_park() {
  if park_job_active; then
    echo "post-stop: a park job ($PARK_UNIT) is already running"
    return 0
  fi
  systemd-run --unit "$PARK_UNIT" --collect --no-block --quiet \
    --description "ai-sandbox: park the $AGENT sandbox (CT $CTID) after GUI Stop" \
    "$(readlink -f "$0")" park-deferred "$AGENT" "$CTID" \
    || die "post-stop: could not schedule the park job (systemd-run). On the host, run: $0 down $AGENT"
}

# INTERNAL: body of $PARK_UNIT (run by systemd, outside any PVE task, with
# no shell environment: settings come from the config files, as in hooks).
cmd_park_deferred() {
  exec 9>"$LOCK_FILE"
  flock -w 600 9 || die "park: timed out waiting for the $AGENT serial lock"
  local waited=0
  while systemctl is-active --quiet "pve-container@${CTID}" 2>/dev/null; do
    [ "$waited" -lt 180 ] || die "park: CT $CTID still not fully stopped after 3 minutes. On the host, run: $0 down $AGENT"
    sleep 2; waited=$((waited + 2))
  done
  ct_exists || { echo "park: CT $CTID is gone - nothing to park"; return 0; }
  ct_running && { echo "park: CT $CTID was started again meanwhile - not parking it"; return 0; }
  stub_is_pristine && { echo "park: CT $CTID is already a fresh stub"; return 0; }
  validate_hardening_config
  park_sandbox
  echo "park: $AGENT sandbox (CT $CTID) clobbered and parked as a fresh stub - ready for GUI Start"
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

# Provisioned marker (#15). Proxmox ignores a failing post-start hook and
# still ends the Start task "TASK OK", so the green tick proves nothing.
# provision_and_report clears this mark first and writes it only as its
# very last step; destroy and pre-start clear it too. `status` reads it:
# a running CT without it was never (fully) provisioned.
mark_provisioned() {
  mkdir -p "$(dirname "$PROVISIONED_MARKER")"
  printf '%s\n' "$CTID" > "$PROVISIONED_MARKER"
}

clear_provisioned() { rm -f "$PROVISIONED_MARKER"; }

is_provisioned() {
  [ -f "$PROVISIONED_MARKER" ] && [ "$(cat "$PROVISIONED_MARKER" 2>/dev/null)" = "$CTID" ]
}

# Make a failed build say so in plain words at the end of its output (the
# PVE task log, or the terminal): set -e failures otherwise end on whatever
# the failing command printed, e.g. `vibe: command not found`.
# Cleared with `trap - EXIT` once provisioning has succeeded.
trap_provision_failure() {   # $1 = label (up | post-start)
  PROVISION_LABEL="$1"
  trap report_provision_failure EXIT
}

report_provision_failure() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  echo "$PROVISION_LABEL: provisioning FAILED (exit $rc) - the $AGENT sandbox is NOT ready (Proxmox may still mark the task OK). Read the output above, then on the host run: $0 up $AGENT"
}

stub_is_pristine() {
  [ -f "$STUB_MARKER" ] && [ "$(cat "$STUB_MARKER" 2>/dev/null)" = "$CTID" ] \
    && ct_exists && ! ct_running
}

# The stub's net0 firewall flag was fixed when it was parked; if FIREWALL or
# EGRESS_POLICY changed since, the CT config would need editing, which
# pre-start cannot do under Proxmox's lock.
stub_firewall_consistent() {
  local net0
  net0="$(ct_conf "$CTID" | awk '/^net0:/ {print $2}')"
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
provision_script() {   # "$@" = agents to install (default: $AGENT)
  local a agents=("$@")
  [ "${#agents[@]}" -gt 0 ] || agents=("$AGENT")
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
apt-get install -y -qq --no-install-recommends -o Dpkg::Use-Pty=0 \
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
EOF
  for a in "${agents[@]}"; do
    echo
    echo "# ---- agent profile: $a install ----"
    "profile_${a}_install"
    echo
    echo "# ---- agent profile: $a verify ----"
    "profile_${a}_verify"
  done
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
  clear_provisioned
  local prov hook
  if [ -n "$(ct_golden_base)" ]; then
    validate_spawn_config
    spawn_provision
  else
    echo "provisioning base toolchain and $PROFILE_LABEL ..."
    prov="$(mktemp)"
    provision_script > "$prov"
    ct_push_file "$prov" /root/provision-base.sh 700
    ct_run bash /root/provision-base.sh
    rm -f "$prov"
  fi

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

  mark_provisioned   # last step: only a complete provisioning sets it
}

print_ssh_line() {
  local ip="${1:-$(sandbox_ip)}"
  if [ -n "$SSH_KEY_FILE" ]; then
    echo "  ssh -i ${SSH_KEY_FILE} root@${ip}"
  else
    echo "  ssh root@${ip}"
  fi
  echo "  (or on this host: $(readlink -f "$0") ssh ${AGENT})"
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

# --------------------------- golden template (bake) --------------------------
# #9: do the expensive build once (`bake`, weekly), then start sessions as
# linked clones of the result. `bake` builds a CT from the Debian template
# with the baseline and EVERY agent's CLI (BAKE_AGENTS), strips what must
# never be shared between sessions (SSH host keys, machine-id, root's
# authorized_keys, the provisioning script, caches), refuses if any
# profile's credential path exists in the image, then `pct template`s it.
#
# Two slots (GOLDEN_CTIDS, default 1048,1049), used alternately: Proxmox
# cannot destroy a template while linked clones still use its base disk,
# so a bake never touches the CURRENT golden. It builds into the other
# slot, destroying the old template there only if no CT's rootfs still
# references it. Running sessions keep their old golden until they are
# rebuilt; a failed bake leaves the current golden untouched (and the
# half-built CT in the other slot for inspection; the next bake replaces it).
#
# The golden is a pseudo-instance named "golden" (hostname
# ai-sandbox-golden, state under $STATE_DIR/golden), so it shares the
# lock, firewall, guard and destroy code with the agent instances. The
# hook ignores it ("golden" is never a profile) and it has no hookscript.
# Needs a rootfs STORAGE that supports linked clones (lvmthin, zfspool, rbd).

GOLDEN_SLOTS=()
BAKE_AGENT_LIST=()

storage_type() {   # $1 = storage ID; echoes its type from $STORAGE_CFG
  awk -v s="$1" '/^[a-z]+: / && $2 == s { sub(/:$/, "", $1); print $1; exit }' "$STORAGE_CFG" 2>/dev/null
}

golden_storage_ok() {
  local t
  t="$(storage_type "$STORAGE")"
  case "$t" in
    lvmthin|zfspool|rbd) return 0 ;;
  esac
  die "bake: storage '$STORAGE' (type '${t:-unknown}' in $STORAGE_CFG) cannot hold linked clones; use an lvmthin, zfspool or rbd storage (STORAGE=...)"
}

golden_current() {   # echoes the current golden CTID, if recorded
  local f="${STATE_DIR}/golden/current" id
  [ -f "$f" ] || return 0
  id="$(cat "$f" 2>/dev/null)"
  [[ "$id" =~ ^[0-9]+$ ]] && echo "$id"
  return 0
}

golden_clones_of() {   # $1 = golden CTID; echoes CTs whose rootfs is a linked clone of it
  local vmid
  for vmid in $(ct_list); do
    [ "$vmid" = "$1" ] && continue
    [ "$(ct_golden_base "$vmid")" = "$1" ] && echo "$vmid"
  done
  return 0
}

# Resolve settings for `bake`: global config only (the golden serves every
# agent), the two slots, the agents to bake in, then the slot to build in.
select_golden() {
  AGENT=golden
  load_config_file "${STATE_DIR}/config.env"
  local s a profile_ids
  GOLDEN_CTIDS="${GOLDEN_CTIDS:-1048,1049}"
  mapfile -t GOLDEN_SLOTS < <(csv_entries "$GOLDEN_CTIDS")
  [ "${#GOLDEN_SLOTS[@]}" -eq 2 ] && [ "${GOLDEN_SLOTS[0]}" != "${GOLDEN_SLOTS[1]}" ] \
    || die "GOLDEN_CTIDS='$GOLDEN_CTIDS' must be two different CT IDs, e.g. 1048,1049"
  profile_ids=" $(for a in $(list_profiles); do ( "profile_${a}_meta"; echo "$PROFILE_CTID" ); done | paste -sd' ' -) "
  for s in "${GOLDEN_SLOTS[@]}"; do
    [[ "$s" =~ ^[0-9]+$ ]] && [ "$s" -ge 100 ] || die "invalid golden CT ID '$s' in GOLDEN_CTIDS"
    [[ "$profile_ids" != *" $s "* ]] || die "golden CT ID $s collides with an agent's CTID; change GOLDEN_CTIDS"
  done
  BAKE_AGENTS="${BAKE_AGENTS:-all}"
  if [ "$BAKE_AGENTS" = all ]; then
    read -r -a BAKE_AGENT_LIST <<<"$(list_profiles)"
  else
    mapfile -t BAKE_AGENT_LIST < <(csv_entries "$BAKE_AGENTS")
  fi
  [ "${#BAKE_AGENT_LIST[@]}" -gt 0 ] || die "BAKE_AGENTS='$BAKE_AGENTS' names no agent"
  for a in "${BAKE_AGENT_LIST[@]}"; do
    profile_exists "$a" || die "unknown agent '$a' in BAKE_AGENTS; known agents: $(list_profiles)"
    declare -F "profile_${a}_credential_paths" >/dev/null \
      || die "profile '$a' has no credential_paths part; bake cannot prove its credential stays out of the image"
  done
  CTID="$(golden_pick_slot)"
  PROFILE_CTID="$CTID"
  PROFILE_LABEL="golden template"
  PROFILE_VSCODE_EXT=""
  apply_defaults
}

golden_pick_slot() {   # echoes the slot to bake into; never the current golden
  local cur s users
  cur="$(golden_current)"
  for s in "${GOLDEN_SLOTS[@]}"; do
    [ "$s" != "$cur" ] && ! ct_conf "$s" >/dev/null && { echo "$s"; return 0; }
  done
  for s in "${GOLDEN_SLOTS[@]}"; do
    [ "$s" = "$cur" ] && continue
    users="$(golden_clones_of "$s" | paste -sd' ' -)"
    [ -z "$users" ] && { echo "$s"; return 0; }
    die "bake: both golden slots are busy - CT $cur is the current golden, and CT $s still backs linked clone(s): $users. Rebuild those sandboxes ('up <agent>', or GUI Stop) so they move to CT $cur, then bake again"
  done
  die "bake: no usable golden slot in GOLDEN_CTIDS='$GOLDEN_CTIDS'"
}

# Everything a session must not inherit from the image. Runs in the build CT
# after provisioning; Debian regenerates machine-id at boot, and spawn
# regenerates SSH host keys and re-injects root's authorized key.
golden_strip_script() {
  cat <<'EOF'
set -e
rm -f /etc/ssh/ssh_host_*
# every clone boots without host keys: let sshd make its own before its
# config test, instead of failing until spawn fixes it
mkdir -p /etc/systemd/system/ssh.service.d
printf '[Service]\nExecStartPre=\nExecStartPre=/usr/bin/ssh-keygen -A\nExecStartPre=/usr/sbin/sshd -t\n' \
  > /etc/systemd/system/ssh.service.d/10-ai-sandbox-hostkeys.conf
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
rm -f /root/.ssh/authorized_keys /root/provision-base.sh /root/.bash_history
apt-get clean
rm -rf /tmp/* /var/tmp/* /root/.cache
journalctl --rotate --vacuum-time=1s >/dev/null 2>&1 || true
EOF
}

# Fail closed if any agent's credential is in the image. Nothing injects
# credentials during a bake; this proves it rather than assuming it.
golden_leak_check() {
  local a p leaks=""
  for a in "${BAKE_AGENT_LIST[@]}"; do
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      ct_run test -e "$p" && leaks="${leaks}  $a: $p"$'\n'
    done < <("profile_${a}_credential_paths")
  done
  [ -z "$leaks" ] || die "bake: credential path(s) present in the golden image - refusing to template it:"$'\n'"${leaks}CT $CTID is left stopped for inspection; the current golden is unchanged"
}

report_bake_failure() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  echo "bake: FAILED (exit $rc) - CT $CTID was not templated; the current golden$(c="$(golden_current)"; [ -n "$c" ] && echo " (CT $c)") is unchanged. Read the output above, then re-run: $0 bake"
}

cmd_bake() {
  self_check bake
  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  lock_or_die
  validate_hardening_config
  golden_storage_ok
  local prev a v stamp tmp
  prev="$(golden_current)"
  destroy_sandbox   # the old template in this slot, if any (guarded; never the current one)
  shared_setup
  ensure_template
  echo "baking golden template in CT $CTID for: ${BAKE_AGENT_LIST[*]} (from $TEMPLATE) ..."
  trap report_bake_failure EXIT
  configure_firewall
  local net0="name=eth0,bridge=${BRIDGE},ip=dhcp"
  firewall_active && net0="${net0},firewall=1"
  pct create "$CTID" "$TEMPLATE" \
    --hostname "$CTHOST" \
    --cores "$CORES" --memory "$RAM_MB" --swap "$SWAP_MB" \
    --rootfs "${STORAGE}:${DISK_GB}" \
    --net0 "$net0" \
    --unprivileged 1 \
    --features nesting=1 \
    --tags "${SANDBOX_TAG};golden" \
    --onboot 0 \
    --start 1
  wait_for_ip >/dev/null || die "bake: CT $CTID started but got no IP (check ${BRIDGE}/DHCP)"

  echo "provisioning base toolchain and ${BAKE_AGENT_LIST[*]} ..."
  tmp="$(mktemp)"
  provision_script "${BAKE_AGENT_LIST[@]}" > "$tmp"
  ct_push_file "$tmp" /root/provision-base.sh 700
  rm -f "$tmp"
  ct_run bash /root/provision-base.sh

  stamp="baked=$(date -u +%Y-%m-%dT%H:%M:%SZ) ctid=$CTID agents=$(IFS=,; echo "${BAKE_AGENT_LIST[*]}")"
  for a in "${BAKE_AGENT_LIST[@]}"; do
    v="$(ct_run bash -c "$("profile_${a}_verify")" 2>&1 | head -n1)" || true
    stamp="${stamp}"$'\n'"${a}: ${v:-unknown}"
  done
  tmp="$(mktemp)"
  printf '%s\n' "$stamp" > "$tmp"
  ct_push_file "$tmp" /etc/ai-sandbox-golden 444
  rm -f "$tmp"

  echo "stripping host keys, machine-id, authorized_keys and caches ..."
  ct_run bash -c "$(golden_strip_script)"
  golden_leak_check

  pct stop "$CTID"
  remove_firewall   # the template never runs; each clone gets its own ruleset
  pct template "$CTID"
  mkdir -p "$INSTANCE_DIR"
  printf '%s\n' "$CTID" > "${INSTANCE_DIR}/current"
  printf '%s\n' "$stamp" > "${INSTANCE_DIR}/stamp"
  trap - EXIT

  echo "golden template ready: CT $CTID"
  sed 's/^/  /' <<<"$stamp"
  [ -n "$prev" ] && echo "previous golden CT $prev is kept while sandboxes still run from it; the next bake reuses its slot"
  # parked, never-booted stubs hold nothing: move them onto the new golden
  for a in $(list_profiles); do
    "$(readlink -f "$0")" refresh-stub "$a" || echo "warning: could not refresh the $a stub; it moves at its next park" >&2
  done
  return 0
}

# --------------------------- weekly bake timer (#9, part 3) --------------------
# `timer on` installs ai-sandbox-bake.service (oneshot: this script's `bake`)
# and ai-sandbox-bake.timer (OnCalendar=$BAKE_SCHEDULE, default Sunday
# 03:00, Persistent so a missed run happens at next boot, up to 30 min
# random delay). Settings come from the config files at run time, as in
# hooks. A bake that cannot run (both golden slots busy) fails the unit
# and leaves everything as it was; `timer` shows the last result.

timer_schedule_ok() {   # $1 = OnCalendar expression; reject anything that could inject unit lines
  [[ "$1" =~ ^[A-Za-z0-9\ :*,./~-]+$ ]] || return 1
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "$1" >/dev/null 2>&1 || return 1
  fi
  return 0
}

timer_unit_write() {   # $1 = path, stdin = content; never overwrite a unit we did not write
  if [ -f "$1" ] && ! grep -qF "$UNIT_MARKER" "$1"; then
    die "refusing to overwrite $1: not written by this script"
  fi
  cat > "$1"
}

cmd_timer() {   # $1 = on | off | (empty: show)
  [ "$EUID" -eq 0 ] || die "must run as root on the Proxmox host"
  local action="${1:-show}" svc="${SYSTEMD_UNIT_DIR}/${BAKE_UNIT}.service" tmr="${SYSTEMD_UNIT_DIR}/${BAKE_UNIT}.timer"
  BAKE_SCHEDULE="${BAKE_SCHEDULE:-Sun *-*-* 03:00:00}"
  case "$action" in
    on)
      timer_schedule_ok "$BAKE_SCHEDULE" || die "invalid BAKE_SCHEDULE='$BAKE_SCHEDULE' (a systemd OnCalendar expression, e.g. 'Sun *-*-* 03:00:00')"
      mkdir -p "$SYSTEMD_UNIT_DIR"
      timer_unit_write "$svc" <<EOF
$UNIT_MARKER
[Unit]
Description=ai-sandbox: bake a fresh golden template
Wants=network-online.target
After=network-online.target pve-cluster.service

[Service]
Type=oneshot
Nice=10
ExecStart=$(readlink -f "$0") bake
EOF
      timer_unit_write "$tmr" <<EOF
$UNIT_MARKER
[Unit]
Description=ai-sandbox: weekly golden template bake

[Timer]
OnCalendar=$BAKE_SCHEDULE
Persistent=true
RandomizedDelaySec=30min

[Install]
WantedBy=timers.target
EOF
      systemctl daemon-reload
      systemctl enable --now "${BAKE_UNIT}.timer"
      echo "bake timer: on ($BAKE_SCHEDULE, up to 30 min later; missed runs catch up at boot)"
      echo "  runs: $(readlink -f "$0") bake   - logs: journalctl -u ${BAKE_UNIT}.service"
      ;;
    off)
      systemctl disable --now "${BAKE_UNIT}.timer" >/dev/null 2>&1 || true
      local f
      for f in "$tmr" "$svc"; do
        [ -f "$f" ] || continue
        grep -qF "$UNIT_MARKER" "$f" || die "refusing to remove $f: not written by this script"
        rm -f "$f"
      done
      systemctl daemon-reload
      echo "bake timer: off (run '$0 bake' by hand when you want a fresh golden)"
      ;;
    show)
      if [ ! -f "$tmr" ]; then
        echo "bake timer: off (turn it on with: $0 timer on)"
        return 0
      fi
      echo "bake timer: on ($(sed -n 's/^OnCalendar=//p' "$tmr"))"
      systemctl list-timers "${BAKE_UNIT}.timer" --all --no-pager 2>/dev/null | sed -n '1,2p' | sed 's/^/  /'
      # systemd reports Result=success for a unit that never ran: check it started
      local started result
      started="$(systemctl show "${BAKE_UNIT}.service" -p ExecMainStartTimestamp --value 2>/dev/null)"
      result="$(systemctl show "${BAKE_UNIT}.service" -p Result --value 2>/dev/null)"
      if [ -z "$started" ] || [ "$started" = "n/a" ]; then
        echo "  last bake: never run yet (to run one now: systemctl start ${BAKE_UNIT}.service)"
      else
        echo "  last bake: ${result:-unknown} (started $started) - logs: journalctl -u ${BAKE_UNIT}.service"
      fi
      ;;
    *) die "usage: $0 timer [on|off]" ;;
  esac
}

print_golden_summary() {   # one line per golden slot that exists, for `status`
  local cur vmid host role users
  cur="$(golden_current)"
  for vmid in $(ct_list); do
    host="$(ct_conf "$vmid" | awk '/^hostname:/ {print $2}')"
    [ "$host" = "ai-sandbox-golden" ] || continue
    role="previous"; [ "$vmid" = "$cur" ] && role="current"
    users="$(golden_clones_of "$vmid" | paste -sd' ' -)"
    if ct_conf "$vmid" | grep -q '^template: 1'; then
      printf 'golden: CT %s template (%s)%s%s\n' "$vmid" "$role" \
        "$([ "$role" = current ] && [ -f "${STATE_DIR}/golden/stamp" ] && echo ", $(head -n1 "${STATE_DIR}/golden/stamp")")" \
        "${users:+, linked clones: $users}"
    else
      printf 'golden: CT %s NOT a template (failed or interrupted bake; the next bake replaces it)\n' "$vmid"
    fi
  done
  [ -f "${SYSTEMD_UNIT_DIR}/${BAKE_UNIT}.timer" ] \
    && echo "bake timer: on ($(sed -n 's/^OnCalendar=//p' "${SYSTEMD_UNIT_DIR}/${BAKE_UNIT}.timer")) - details: $0 timer"
  return 0
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

  echo "building $AGENT sandbox (CT $CTID, $PROFILE_LABEL) ..."
  trap_provision_failure up
  create_sandbox start

  local ip
  ip="$(wait_for_ip)" || { echo "container started but no IP (check ${BRIDGE}/DHCP)"; exit 1; }

  # fresh host key per rebuild: drop the stale host-side entry now
  purge_known_hosts "$ip"

  provision_and_report
  trap - EXIT
  print_hardening_summary
  warn_public_ipv6
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
  mac="$(ct_conf "$CTID" | awk -F'[,=]' '/^net0:/ {for (i=1;i<=NF;i++) if ($i=="hwaddr") print $(i+1)}')"
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
  host="$(ct_conf "$1" | awk '/^hostname:/ {print $2}')" || return 0
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
#   post-stop  — schedule the park ($PARK_UNIT: clobber + fresh stub), which
#                runs once PVE has released the CT (see schedule_park)
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
  # One stream for the PVE task log: it reads stdout and stderr separately,
  # so warnings otherwise land out of order (after "ready via GUI").
  exec 2>&1
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
      # checked before hook_lock: the park job holds the serial lock, and a
      # lock holder would otherwise make this phase pass through and boot
      # a CT that was never checked (this is also what refuses GUI Restart)
      ! park_job_active || die "pre-start: CT $CTID is still being parked after the last Stop (unit $PARK_UNIT). Wait a minute, then Start again (GUI Restart always hits this: use Stop, then Start). Progress: journalctl -u $PARK_UNIT"
      hook_lock "$phase" || exit 0
      validate_hardening_config
      guard_ct
      stub_is_pristine || die "pre-start: CT $CTID is not a fresh stub (it has booted since it was built, or was not parked by 'down' / GUI Stop). GUI Start cannot rebuild it, because Proxmox holds the CT's lock during Start. On the host, run: $0 up $AGENT"
      stub_firewall_consistent || die "pre-start: firewall settings changed since CT $CTID was parked (FIREWALL=$FIREWALL, EGRESS_POLICY=$EGRESS_POLICY). On the host, run: $0 up $AGENT"
      configure_firewall   # refresh the host-side ruleset (a file under /etc/pve/firewall, not the CT config)
      clear_stub_marker    # booting now: from here on this is a used disk
      clear_provisioned
      echo "pre-start: CT $CTID is a fresh, never-booted stub - starting it"
      ;;  # PVE now boots the stub; post-start provisions it
    post-start)
      hook_lock "$phase" || exit 0
      trap_provision_failure post-start
      guard_ct
      local ip
      ip="$(wait_for_ip)" || die "post-start: no IP (check ${BRIDGE}/DHCP)"
      purge_known_hosts "$ip"
      provision_and_report
      trap - EXIT
      print_hardening_summary
      warn_public_ipv6
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
      # no guard_ct here: it may `pct set` (legacy tag heal), which needs
      # the lock this task holds; the park job guards before it touches
      # anything (clobber_disk and destroy_sandbox both call guard_ct)
      schedule_park
      echo "post-stop: parking the $AGENT sandbox (CT $CTID) once Proxmox releases it (unit $PARK_UNIT, about a minute);"
      echo "  GUI Start works when it is done. Progress: journalctl -u $PARK_UNIT"
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
    local prov
    if is_provisioned; then
      prov="provisioned"
    elif ! flock -n "$LOCK_FILE" true 2>/dev/null; then
      prov="provisioning in progress"
    else
      prov="NOT provisioned (see the Start task log, or run '$0 up $AGENT')"
    fi
    echo "$AGENT: CT $CTID running, ${prov}, ip: $(sandbox_ip), firewall: ${fw_info}"
  else
    if park_job_active; then
      echo "$AGENT: CT $CTID stopped: being parked after GUI Stop (unit $PARK_UNIT); GUI Start works when done, firewall: ${fw_info}"
    elif stub_is_pristine; then
      echo "$AGENT: CT $CTID stopped: fresh stub, ready for GUI Start, firewall: ${fw_info}"
    else
      echo "$AGENT: CT $CTID stopped: NOT a fresh stub (GUI Start will refuse; run '$0 up $AGENT'), firewall: ${fw_info}"
    fi
  fi
  local base
  base="$(ct_golden_base)"
  if [ -n "$base" ]; then
    echo "  built from: golden CT $base$([ "$base" = "$(golden_current)" ] && echo " (current)" || echo " (previous; the next park or up moves it to the current golden)")"
  else
    echo "  built from: full rebuild"
  fi
}

# Every ai-sandbox CT on this node, whichever agent and CTID.
cmd_status_all() {
  local vmid host state ip ready found=0
  printf '%-10s %-6s %-8s %-15s %s\n' AGENT CTID STATE IP PROVISIONED
  for vmid in $(ct_list); do
    host="$(ct_conf "$vmid" | awk '/^hostname:/ {print $2}')"
    case "$host" in ai-sandbox-golden) continue ;; ai-sandbox-?*) ;; *) continue ;; esac
    found=1
    state="stopped"; ct_id_running "$vmid" && state="running"
    ip=""
    [ "$state" = "running" ] && ip="$(ct_attach "$vmid" sh -c 'hostname -I 2>/dev/null | cut -d" " -f1' 2>/dev/null || true)"
    ready="-"
    if [ "$state" = "running" ]; then
      ready="NO"
      [ "$(cat "${STATE_DIR}/${host#ai-sandbox-}/provisioned" 2>/dev/null)" = "$vmid" ] && ready="yes"
    fi
    printf '%-10s %-6s %-8s %-15s %s\n' "${host#ai-sandbox-}" "$vmid" "${state:-?}" "${ip:--}" "$ready"
  done
  [ "$found" = 1 ] || echo "(no ai-sandbox CTs on this node)"
  print_golden_summary
}

cmd_agents() {
  local a
  for a in $(list_profiles); do
    ( "profile_${a}_meta"; printf '%-10s CT %-6s %s\n' "$a" "$PROFILE_CTID" "$PROFILE_LABEL" )
  done
}

# ssh into the sandbox with the managed key: `ssh <agent> [command...]`.
# Host keys rotate on every rebuild; build paths purge the stale
# known_hosts entry, and accept-new records the fresh key on first use
# (a key CHANGING under a live sandbox would still be refused).
cmd_ssh() {   # "$@" = optional remote command
  ct_running || die "$AGENT sandbox not running; run '$0 up $AGENT' first"
  local ip keyargs=()
  ip="$(sandbox_ip)"
  [ -n "$ip" ] || die "no IP for the $AGENT sandbox (check ${BRIDGE}/DHCP)"
  [ -z "$SSH_PUBKEY" ] && keyargs=(-i "$SSH_KEY_FILE" -o IdentitiesOnly=yes)
  exec ssh "${keyargs[@]}" -o StrictHostKeyChecking=accept-new "root@${ip}" "$@"
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
  local self tmp bak repo
  if repo="$(script_git_checkout)"; then
    die "this copy lives in the git checkout at $repo - update it with: git -C $repo pull"
  fi
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
load_dropin_profiles

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  up|down|purge|reset|shell|ip|export) select_agent "${1:-}" ;;
  ssh)    # ssh <agent> [command...]; the agent may come from AGENT= instead
    if [ $# -gt 0 ] && profile_exists "$1"; then select_agent "$1"; shift
    else select_agent ""; fi ;;
  status) [ -z "${1:-${AGENT:-}}" ] || select_agent "${1:-}" ;;
  bake)   select_golden ;;
  refresh-stub) select_agent "${1:-}" ;;
  timer)  load_config_file "${STATE_DIR}/config.env" ;;
  park-deferred)   # <agent> <vmid>: the vmid wins over config, as in hooks
    [[ "${2:-}" =~ ^[0-9]+$ ]] || die "park-deferred: usage: $0 park-deferred <agent> <vmid>"
    CTID="$2"; select_agent "${1:-}" ;;
esac
case "$cmd" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  purge)  cmd_purge ;;
  reset)  cmd_down; cmd_up ;;
  status) if [ -n "${AGENT:-}" ]; then cmd_status; else cmd_status_all; fi ;;
  ip)     sandbox_ip ;;
  shell)  cmd_shell ;;
  ssh)    cmd_ssh "$@" ;;
  export) cmd_export ;;
  agents) cmd_agents ;;
  update) cmd_update ;;
  hook)   cmd_hook "$@" ;;
  park-deferred) cmd_park_deferred ;;
  bake)   cmd_bake ;;
  refresh-stub) cmd_refresh_stub ;;
  timer)  cmd_timer "${1:-}" ;;
  *) awk 'NR == 1 || /^# ====/ {next} /^set -/ {exit} /^#/ {sub(/^# ?/, ""); print}' "$0"; exit 1 ;;
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

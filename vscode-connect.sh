#!/usr/bin/env bash
# vscode-connect.sh: open VS Code straight into an ai-sandbox agent
# instance, refreshing the desktop ssh entry first, so no manual export
# fetching after rebuilds. Companion to ai-sandbox.sh
# (https://github.com/itsfja/AI-sandbox).
#
# Usage (Linux/macOS):
#   PVE_HOST=root@192.168.3.188 bash vscode-connect.sh mistral             # opens /root
#   PVE_HOST=root@192.168.3.188 bash vscode-connect.sh mistral /root/work  # other folder
#   (or AGENT=mistral in the environment instead of the first argument)
#
# Required env var:
#   PVE_HOST    Proxmox host to reach over ssh, e.g. root@192.168.3.188
#               (needs an account that can read the sandbox key there,
#               root by default, and the host reachable from your LAN)
# Optional env overrides:
#   PVE_SCRIPT  path of ai-sandbox.sh on the host (default /root/ai-sandbox.sh)
#   PVE_KEY     path of the managed sandbox private key on the host
#               (default /root/.ai-sandbox/ssh/ai-sandbox — one key for every agent)
#   SSH_ALIAS   desktop ssh alias for the sandbox (default ai-sandbox-<agent>)
#
# Per run:
#   1. Fast path: try the ssh alias as-is. If it works (DHCP reservation
#      holding, or nothing rebuilt), no host contact at all.
#   2. Stale path (a rebuild changed the IP): ask the PVE host for the
#      current sandbox IP, rewrite ONLY this script's marked block in
#      ~/.ssh/config (a previous manual 'Host <alias>' block is replaced,
#      other hosts — and other agents' blocks — untouched), fetch the
#      permanent private key once if missing, and wait for ssh to come good.
#   3. Open VS Code in the remote: code --folder-uri
#      vscode-remote://ssh-remote+ai-sandbox-<agent>/<workspace>
# Extension push: list the agent's extension in "remote.SSH.defaultExtensions"
#   in desktop settings.json and Remote-SSH installs it into the sandbox on
#   every connect (the code CLI has no switch for the remote slot);
#   '/root/ai-sandbox.sh export <agent>' prints the extension ID.

set -euo pipefail

die() { echo "vscode-connect: $*" >&2; exit 1; }
note() { echo "vscode-connect: $*"; }

AGENT="${1:-${AGENT:-}}"
[[ "$AGENT" =~ ^[a-z][a-z0-9]{0,15}$ ]] \
  || die "usage: bash vscode-connect.sh <agent> [folder]  (e.g. mistral; '/root/ai-sandbox.sh agents' on the host lists them)"
PVE_HOST="${PVE_HOST:-}"
PVE_SCRIPT="${PVE_SCRIPT:-/root/ai-sandbox.sh}"
PVE_KEY="${PVE_KEY:-/root/.ai-sandbox/ssh/ai-sandbox}"
SSH_ALIAS="${SSH_ALIAS:-ai-sandbox-$AGENT}"
WORKSPACE="${2:-/root}"
SSH_DIR="$HOME/.ssh"
KEY_FILE="$SSH_DIR/ai-sandbox"
CONFIG_FILE="$SSH_DIR/config"
MARK_BEGIN="# BEGIN $SSH_ALIAS (managed by vscode-connect.sh; do not edit between markers)"
MARK_END="# END $SSH_ALIAS"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)

launch() {
  note "opening VS Code in ssh-remote+${SSH_ALIAS}${WORKSPACE} ..."
  note "first connect after a rebuild downloads vscode-server; the agent's extension reinstalls itself when listed in remote.SSH.defaultExtensions (README: VS Code setup), else one 'Install in SSH: $SSH_ALIAS' click."
  exec code --folder-uri "vscode-remote://ssh-remote+${SSH_ALIAS}${WORKSPACE}"
}

command -v ssh  >/dev/null 2>&1 || die "ssh not found (install openssh-client)"
command -v code >/dev/null 2>&1 || die "'code' CLI not found (in VS Code: Command Palette > 'Shell Command: Install code command in PATH')"
[ -n "$PVE_HOST" ] || die "PVE_HOST is not set, e.g. PVE_HOST=root@192.168.3.188 bash vscode-connect.sh $AGENT (transient: that shell only)
  or make it permanent: add 'export PVE_HOST=root@192.168.3.188' to ~/.bashrc (macOS: ~/.zshrc)"
case "$WORKSPACE" in /*) ;; *) WORKSPACE="/$WORKSPACE" ;; esac

probe() { ssh "${SSH_OPTS[@]}" "$SSH_ALIAS" true >/dev/null 2>&1; }

# --- fast path: alias already works ------------------------------------
if probe; then
  launch
fi

# --- stale path: refresh from the host ---------------------------------
note "ssh $SSH_ALIAS failed (stale IP after a rebuild?), refreshing from $PVE_HOST ..."

new_ip="$(ssh "$PVE_HOST" "$PVE_SCRIPT ip $AGENT" | head -n 1)" \
  || die "could not reach the Proxmox host at $PVE_HOST"
[ -n "$new_ip" ] || die "the $AGENT sandbox is not running (no IP). Run '$PVE_SCRIPT up $AGENT' on the Proxmox host first."
case "$new_ip" in *[[:space:]]*) die "unexpected output from '$PVE_SCRIPT ip $AGENT': $new_ip" ;; esac
note "current sandbox IP: $new_ip"

mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
if [ ! -f "$KEY_FILE" ]; then
  command -v scp >/dev/null 2>&1 || die "scp not found (install openssh-client)"
  scp -q "$PVE_HOST:$PVE_KEY" "$KEY_FILE" || die "could not fetch the sandbox key from $PVE_HOST:$PVE_KEY"
  chmod 600 "$KEY_FILE"
  note "sandbox keypair installed once at $KEY_FILE (it is permanent; rebuilds reuse it)."
fi

# Rewrite ONLY the managed block: drop the previous managed block and any
# legacy unmarked 'Host <alias>' block left by the manual export flow,
# keep every other host entry untouched, then append a fresh marked block.
tmp="$(mktemp)"
if [ -f "$CONFIG_FILE" ]; then
  awk -v begin="$MARK_BEGIN" -v end="$MARK_END" -v alias_re='^Host[ \t]+'"$SSH_ALIAS"'[ \t]*$' '
    $0 == begin { inm = 1; next }
    $0 == end   { inm = 0; next }
    inm         { next }
    inl && $0 ~ /^(Host|Match)[ \t]/ { inl = 0 }   # end of legacy block
    $0 ~ alias_re { inl = 1; next }
    inl        { next }
    { print }
  ' "$CONFIG_FILE" > "$tmp"
else
  : > "$tmp"
fi
{
  printf '%s\n' "$MARK_BEGIN"
  printf 'Host %s\n' "$SSH_ALIAS"
  printf '    HostName %s\n' "$new_ip"
  printf '    User root\n'
  printf '    IdentityFile ~/.ssh/ai-sandbox\n'
  printf '    # disposable sandbox: every rebuild mints a FRESH host key, so strict\n'
  printf '    # known-hosts checking would block the 2nd+ rebuild connect; scoped to\n'
  printf '    # this Host alias only.\n'
  printf '    StrictHostKeyChecking no\n'
  printf '    UserKnownHostsFile /dev/null\n'
  printf '%s\n' "$MARK_END"
} >> "$tmp"
touch "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE"
mv "$tmp" "$CONFIG_FILE"
note "ssh config updated: Host $SSH_ALIAS -> $new_ip (only the managed block was touched)."

# A just-started sandbox may still be finishing provisioning; wait a bit.
ok=0
for _ in $(seq 1 15); do
  probe && { ok=1; break; }
  sleep 2
done
[ "$ok" = 1 ] || die "ssh $SSH_ALIAS still fails after refresh. Check the network/DHCP, or run '$PVE_SCRIPT status $AGENT' on the Proxmox host."
launch

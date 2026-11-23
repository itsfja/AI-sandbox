#!/usr/bin/env bash
# Dry-run tests for ai-sandbox.sh against the mock Proxmox commands.
# Needs root (STATE_DIR ownership checks, /run/lock), bash, python3, ssh-keygen.
# Usage: sudo bash tests/run-tests.sh [path/to/ai-sandbox.sh]
set -uo pipefail
[ ! -d /etc/pve ] || { echo "refusing to run on a Proxmox host: the tests clear /run/lock/ai-sandbox.* (live locks)" >&2; exit 2; }
SRC="$(readlink -f "${1:-$(dirname "$0")/../ai-sandbox.sh}")"
HERE="$(cd "$(dirname "$0")" && pwd)/mock"
pass=0; fail=0
ok()   { echo "  PASS $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*"; fail=$((fail+1)); }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

fresh() {   # new isolated world; sets T and S (script copy)
  T="$(mktemp -d)"; export MOCK_T="$T"
  mkdir -p "$T/state" "$T/fw" "$T/snip" "$T/home/.ssh"
  chmod 700 "$T/state"
  S="$T/ai-sandbox.sh"; cp "$SRC" "$S"; chmod +x "$S"
  rm -f /run/lock/ai-sandbox.*
}
run() {   # run the script copy in the mock world
  env PATH="$HERE/bin:$PATH" HOME="$T/home" STATE_DIR="$T/state" FW_DIR="$T/fw" \
      HOOK_SNIPPET_DIR="$T/snip" AUTO_UPDATE=off TEMPLATE=local:vztmpl/debian-12.tar.zst \
      EXPORT_DIR="$T/export" "$@"
}
add_fake_profile() {   # second agent, to test parallel instances
  python3 - "$S" <<'EOF'
import sys; p=sys.argv[1]; s=open(p).read()
fake='''profile_fake_meta() { PROFILE_CTID=1059; PROFILE_LABEL="Fake CLI"; PROFILE_VSCODE_EXT=""; }
profile_fake_install() { echo "echo installing fake"; }
profile_fake_verify() { echo "fake --version"; }
profile_fake_credentials() { ct_push_file "$SECRETS_FILE" /root/.fake/env 600; }
profile_fake_policy() { local t; t="$(mktemp)"; echo "mcp=$(bool_word "$AGENT_MCP")" > "$t"; ct_push_file "$t" /etc/fake/policy 444; rm -f "$t"; }

'''
marker='# --------------------------- dispatch'
assert s.count(marker)==1
open(p,'w').write(s.replace(marker, fake+marker))
EOF
}

echo "== agents / argument handling"
fresh
out="$(run "$S" agents)"; check "agents lists mistral with CT 1051" grep -q 'mistral *CT 1051 *Mistral Vibe CLI' <<<"$out"
out="$(run "$S" up 2>&1)"; rc=$?
check "up without agent fails" [ $rc -ne 0 ]
check "  ...and names known agents" grep -q 'known agents: mistral' <<<"$out"
out="$(run "$S" up bogus 2>&1)"; check "unknown agent rejected" grep -q "unknown agent 'bogus'" <<<"$out"
out="$(run "$S" up 'Mistral;rm' 2>&1)"; check "invalid agent name rejected" grep -q "unknown agent" <<<"$out"
out="$(run AGENT=mistral "$S" status 2>&1)"; check "AGENT env works for status" grep -q '^mistral: no sandbox (CT 1051 absent)' <<<"$out"
out="$(run "$S" status 2>&1)"; check "status with no agent lists all (none)" grep -q 'no ai-sandbox CTs' <<<"$out"

echo "== full up (no secrets yet)"
fresh
out="$(run "$S" up mistral 2>&1)"; rc=$?
check "up exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -15
check "prints sandbox ready + ssh line" grep -q "ssh -i $T/state/ssh/ai-sandbox root@192.168.3.77" <<<"$out"
check "missing secrets -> warning + mistral hint" grep -q "create a Vibe key at chat.mistral.ai" <<<"$out"
check "CT 1051 created with hostname ai-sandbox-mistral" grep -q '^hostname: ai-sandbox-mistral$' "$T/conf/1051.conf"
check "  ...tagged ai-sandbox" grep -q '^tags: ai-sandbox$' "$T/conf/1051.conf"
check "  ...hookscript attached" grep -q '^hookscript: local:snippets/ai-sandbox-hook.sh$' "$T/conf/1051.conf"
check "  ...firewall=1 and pinned MAC" grep -qE '^net0: .*hwaddr=02:([0-9a-f]{2}:){4}[0-9a-f]{2},firewall=1' "$T/conf/1051.conf"
check "MAC retained under state/mistral/mac" grep -qE '^02:' "$T/state/mistral/mac"
check "shared keypair generated" [ -f "$T/state/ssh/ai-sandbox" ] && [ -f "$T/state/ssh/ai-sandbox.pub" ]
check "ssh dir is 700" [ "$(stat -c %a "$T/state/ssh")" = 700 ]
check "hook shim written and executable" [ -x "$T/snip/ai-sandbox-hook.sh" ]
check "  ...shim calls this script's hook" grep -q "exec $S hook" "$T/snip/ai-sandbox-hook.sh"
check "firewall file has marker + lan-block" grep -q '^# ai-sandbox managed firewall (CT 1051, EGRESS_POLICY=lan-block)' "$T/fw/1051.fw"
P="$T/ct/1051/root/provision-base.sh"
check "provision script pushed" [ -f "$P" ]
check "  ...has baseline apt toolchain" grep -q 'ripgrep man-db sudo locales' "$P"
check "  ...has Vibe installer" grep -q 'curl -LsSf https://mistral.ai/vibe/install.sh | bash' "$P"
check "  ...ends with verify" [ "$(tail -n1 "$P")" = "vibe --version" ]
check "  ...pins key-only root ssh" grep -q '10-ai-sandbox-root-key-only.conf' "$P"
check "  ...is valid bash" bash -n "$P"
C="$T/ct/1051/root/.vibe/config.toml"
check "policy config injected" [ -f "$C" ]
check "  ...mode 400" [ "$(stat -c %a "$C")" = 400 ]
check "  ...all default-deny" [ "$(grep -c '= false$' "$C")" = 3 ]
check "summary line names the agent" grep -q 'hardening: firewall=lan-block (pending Datacenter firewall); mistral=(connectors=off, mcp=off, auto_approve=off)' <<<"$out"

echo "== secrets, overrides, config files"
fresh
mkdir -p "$T/state/mistral"
printf 'MISTRAL_API_KEY=test-not-real\n' > "$T/state/mistral/secrets.env"; chmod 644 "$T/state/mistral/secrets.env"
printf 'CORES=2\nRAM_MB="8192"\nEGRESS_ALLOW=192.168.3.50/32\n' > "$T/state/config.env"
printf '# per-agent\nCORES=8\nAGENT_MCP=on\nBOGUS_EXPANSION=$(touch %s/pwned)\n' "$T" > "$T/state/mistral/config.env"
out="$(run "$S" up mistral 2>&1)"; rc=$?
check "up with config files exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -15
check "agent config beats global (cores 8)" grep -q -- '--cores 8 --memory 8192' "$T/calls.log"
check "global config applies (EGRESS_ALLOW in .fw)" grep -q 'OUT ACCEPT -dest 192.168.3.50/32' "$T/fw/1051.fw"
check "config values are never executed" [ ! -e "$T/pwned" ]
check "secrets pushed to /root/.vibe/.env" grep -q 'MISTRAL_API_KEY=test-not-real' "$T/ct/1051/root/.vibe/.env"
check "  ...mode 600 in CT" [ "$(stat -c %a "$T/ct/1051/root/.vibe/.env")" = 600 ]
check "  ...host file tightened to 600" [ "$(stat -c %a "$T/state/mistral/secrets.env")" = 600 ]
check "AGENT_MCP=on from config -> enable_mcp = true" grep -q '^enable_mcp = true$' "$T/ct/1051/root/.vibe/config.toml"
: > "$T/calls.log"
out="$(run CORES=6 FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check "command-line env beats config files (cores 6)" grep -q -- '--cores 6 ' "$T/calls.log"
check "rebuild keeps the same MAC" grep -q "hwaddr=$(cat "$T/state/mistral/mac")" "$T/conf/1051.conf"
chmod 666 "$T/state/config.env"
out="$(run "$S" status mistral 2>&1)"; check "group/world-writable config refused" grep -q 'refusing .*config.env: group/other-writable' <<<"$out"
chmod 600 "$T/state/config.env"; printf 'AGENT=claude\n' >> "$T/state/config.env"
out="$(run "$S" status mistral 2>&1)"; check "AGENT cannot be set from config" grep -q 'AGENT cannot be set' <<<"$out"
printf 'not a valid line\n' > "$T/state/config.env"
out="$(run "$S" status mistral 2>&1)"; check "malformed config line refused" grep -q 'bad line in' <<<"$out"
printf 'X=1\n' > "$T/state/config.env"; chown 65534 "$T/state/config.env"
out="$(run "$S" status mistral 2>&1)"; check "non-root-owned config refused" grep -q 'not owned by root' <<<"$out"

echo "== ownership guard"
fresh
mkdir -p "$T/conf"; printf 'hostname: wordpress\ntags: web\n' > "$T/conf/1051.conf"
out="$(run "$S" up mistral 2>&1)"; rc=$?
check "foreign CT at 1051 -> up refuses" [ $rc -ne 0 ]
check "  ...with the guard message" grep -q 'refusing to touch CT 1051' <<<"$out"
check "  ...and it still exists" grep -q wordpress "$T/conf/1051.conf"
out="$(run "$S" hook 1051 pre-start 2>&1)"; rc=$?
check "hook ignores a CT that is not ai-sandbox-*" [ $rc -eq 0 ] && grep -q wordpress "$T/conf/1051.conf"

echo "== GUI hook path + down + status/export"
fresh
run "$S" up mistral >/dev/null 2>&1
check "after up: no pristine-stub marker" [ ! -e "$T/state/mistral/pristine-stub" ]
out="$(run FORCE=1 RESCUE=0 "$S" down mistral 2>&1)"; rc=$?
check "down exits 0" [ $rc -eq 0 ]
check "  ...clobbered via blkdiscard -f" grep -q '^blkdiscard -f /dev/' "$T/calls.log"
check "  ...with no clobber failure" bash -c "! grep -q 'blkdiscard failed' <<<\"\$1\"" _ "$out"
check "  ...stub exists, stopped, hook attached" [ -f "$T/conf/1051.conf" ] && [ ! -e "$T/run/1051" ] && grep -q hookscript "$T/conf/1051.conf"
check "  ...pristine-stub marker written for CT 1051" [ "$(cat "$T/state/mistral/pristine-stub" 2>/dev/null)" = 1051 ]
out="$(run "$S" status mistral 2>&1)"
check "status reports a fresh stub" grep -q 'stopped: fresh stub, ready for GUI Start' <<<"$out"
# GUI Start: PVE holds the CT config lock for the whole task and runs
# pre-start env-less; then boots; then runs post-start (lock released).
gui_hook() {   # $1 = vmid, $2 = phase; env-less like PVE
  env -i PATH="$HERE/bin:/usr/bin:/bin" MOCK_T="$T" bash -c "STATE_DIR=$T/state FW_DIR=$T/fw HOOK_SNIPPET_DIR=$T/snip AUTO_UPDATE=off TEMPLATE=local:vztmpl/d.tar.zst $S hook $1 $2" 2>&1
}
mkdir -p "$T/locked"; touch "$T/locked/1051"; : > "$T/calls.log"
out="$(gui_hook 1051 pre-start)"; rc=$?
check "GUI pre-start under the PVE lock succeeds on a fresh stub" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -5
check "  ...without touching the CT (no destroy/create/set)" bash -c "! grep -qE '^pct (destroy|create|set) ' '$T/calls.log'"
check "  ...says it is starting the stub" grep -q 'fresh, never-booted stub' <<<"$out"
check "  ...and consumes the marker" [ ! -e "$T/state/mistral/pristine-stub" ]
rm -f "$T/locked/1051"; touch "$T/run/1051"
out="$(run "$S" hook 1051 post-start 2>&1)"
check "GUI post-start provisions + reports" grep -q 'mistral sandbox ready via GUI' <<<"$out" && [ -f "$T/ct/1051/root/.vibe/config.toml" ]
# a used (booted) CT must not be started again from the GUI
rm -f "$T/run/1051"; touch "$T/locked/1051"; : > "$T/calls.log"
out="$(gui_hook 1051 pre-start)"; rc=$?
check "GUI pre-start refuses a CT that has booted" [ $rc -ne 0 ]
check "  ...pointing at 'up mistral'" grep -q 'is not a fresh stub.*up mistral' <<<"$out"
check "  ...without touching the CT" bash -c "! grep -qE '^pct (destroy|create|set) ' '$T/calls.log'"
rm -f "$T/locked/1051"
out="$(run "$S" status mistral 2>&1)"
check "status flags the used stopped CT" grep -q 'NOT a fresh stub' <<<"$out"
# firewall settings changed between park and Start -> refuse, don't boot
run FORCE=1 RESCUE=0 "$S" down mistral >/dev/null 2>&1
touch "$T/locked/1051"
out="$(gui_hook_fw_off() { env -i PATH="$HERE/bin:/usr/bin:/bin" MOCK_T="$T" bash -c "FIREWALL=off STATE_DIR=$T/state FW_DIR=$T/fw HOOK_SNIPPET_DIR=$T/snip AUTO_UPDATE=off $S hook 1051 pre-start" 2>&1; }; gui_hook_fw_off)"; rc=$?
check "GUI pre-start refuses when firewall settings changed since park" [ $rc -ne 0 ] && grep -q 'firewall settings changed' <<<"$out"
check "  ...and keeps the stub pristine for a later Start" [ -e "$T/state/mistral/pristine-stub" ]
rm -f "$T/locked/1051"
out="$(gui_hook 1051 pre-start)"; rc=$?
check "  ...then starts fine with the original settings" [ $rc -eq 0 ]
touch "$T/run/1051"; run "$S" hook 1051 post-start >/dev/null 2>&1
out="$(run "$S" status 2>&1)"
check "status (all) shows mistral running" grep -qE '^mistral +1051 +running +192\.168\.3\.77' <<<"$out"
out="$(run "$S" export mistral 2>&1)"; rc=$?
check "export exits 0" [ $rc -eq 0 ]
check "  ...ssh-config Host ai-sandbox-mistral" grep -q '^Host ai-sandbox-mistral$' "$T/export/ssh-config"
check "  ...IdentityFile ~/.ssh/ai-sandbox" grep -q 'IdentityFile ~/.ssh/ai-sandbox$' "$T/export/ssh-config"
check "  ...tarball named per agent" [ -f "$T/export/ai-sandbox-mistral-desktop.tar.gz" ]
check "  ...prints the VS Code extension hint" grep -q 'mistralai.mistral-vibe-code' <<<"$out"

echo "== parallel instances (second, fake agent)"
fresh; add_fake_profile
run "$S" up mistral >/dev/null 2>&1
( exec 9>/run/lock/ai-sandbox.mistral.lock; flock -n 9; sleep 5 ) &
holder=$!; sleep 0.5
out="$(run "$S" hook 1051 post-stop 2>&1)"
check "mistral hook passes through while mistral's lock is held" grep -q 'mistral operation in progress — post-stop hook passthrough' <<<"$out"
out="$(run "$S" up fake 2>&1)"; rc=$?
check "fake agent builds while mistral is locked" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -5
check "  ...own CTID/hostname" grep -q '^hostname: ai-sandbox-fake$' "$T/conf/1059.conf"
check "  ...own MAC, different from mistral's" [ "$(cat "$T/state/fake/mac")" != "$(cat "$T/state/mistral/mac")" ]
check "  ...shared keypair reused (one key)" [ "$(ls "$T/state/ssh" | wc -l)" = 2 ]
check "  ...fake policy rendered" grep -q '^mcp=false$' "$T/ct/1059/etc/fake/policy"
out="$(run "$S" hook 1059 post-stop 2>&1)"
check "fake hook does work while mistral is locked" grep -q 'fake sandbox clobbered and parked' <<<"$out"
wait "$holder"
out="$(run "$S" status 2>&1)"
check "status (all) lists both" grep -q '^mistral ' <<<"$out" && grep -q '^fake ' <<<"$out"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

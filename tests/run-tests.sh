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
# check_sh "desc" 'COND': COND is evaluated whole, so `a && b` is ONE check.
# (`check "desc" a && b` runs only `a` inside check; b's result is dropped.)
# Single-quote COND: $out, $rc and $T expand at evaluation time.
check_sh() { local d="$1"; shift; if eval "$1"; then ok "$d"; else bad "$d"; fi; }

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
calls_lack() { ! grep -qE "$1" "$T/calls.log"; }
hookvars() {   # what reaches an env-less hook or systemd unit: the config, not your shell
  echo "STATE_DIR=$T/state FW_DIR=$T/fw HOOK_SNIPPET_DIR=$T/snip AUTO_UPDATE=off TEMPLATE=local:vztmpl/d.tar.zst"
}
run_deferred() {   # $1 = unit; run the job post-stop handed to systemd-run, env-less like a unit
  env -i PATH="$HERE/bin:/usr/bin:/bin" MOCK_T="$T" \
    bash -c "$(hookvars) ${2:-} $(cat "$T/deferred/$1.cmd")" 2>&1
}
# A GUI Stop as PVE runs it: the CT has stopped, but `pct status` still says
# running and the CT config lock is held until post-stop returns. Sets
# STOP_OUT (hook output) and STOP_RC; the park job is left in deferred/.
gui_stop_hook() {   # $1 = vmid
  rm -f "$T/run/$1"; rm -rf "$T/deferred"
  mkdir -p "$T/locked" "$T/stopping" "$T/unit-active"
  touch "$T/locked/$1" "$T/stopping/$1" "$T/unit-active/$1"
  : > "$T/calls.log"
  STOP_OUT="$(env -i PATH="$HERE/bin:/usr/bin:/bin" MOCK_T="$T" bash -c "$(hookvars) $S hook $1 post-stop" 2>&1)"; STOP_RC=$?
  rm -f "$T/locked/$1" "$T/stopping/$1" "$T/unit-active/$1"   # Stop task ends
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
check_sh "shared keypair generated" '[ -f "$T/state/ssh/ai-sandbox" ] && [ -f "$T/state/ssh/ai-sandbox.pub" ]'
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
check_sh "hook ignores a CT that is not ai-sandbox-*" '[ $rc -eq 0 ] && grep -q wordpress "$T/conf/1051.conf"'

echo "== GUI hook path + down + status/export"
fresh
run "$S" up mistral >/dev/null 2>&1
check "after up: no pristine-stub marker" [ ! -e "$T/state/mistral/pristine-stub" ]
out="$(run FORCE=1 RESCUE=0 "$S" down mistral 2>&1)"; rc=$?
check "down exits 0" [ $rc -eq 0 ]
check "  ...clobbered via blkdiscard -f" grep -q '^blkdiscard -f /dev/' "$T/calls.log"
check "  ...with no clobber failure" bash -c "! grep -q 'blkdiscard failed' <<<\"\$1\"" _ "$out"
check_sh "  ...stub exists, stopped, hook attached" '[ -f "$T/conf/1051.conf" ] && [ ! -e "$T/run/1051" ] && grep -q hookscript "$T/conf/1051.conf"'
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
# PVE boots it and runs post-start STILL holding the CT config lock
touch "$T/run/1051"; : > "$T/calls.log"
out="$(gui_hook 1051 post-start)"; rc=$?
check_sh "GUI post-start under the PVE lock provisions + reports" '[ $rc -eq 0 ] && grep -q "mistral sandbox ready via GUI" <<<"$out"'
[ $rc -eq 0 ] || echo "$out" | tail -5
check_sh "  ...provision script, credentials-free policy file in place" '[ -f "$T/ct/1051/root/provision-base.sh" ] && [ -f "$T/ct/1051/root/.vibe/config.toml" ]'
check "  ...without pct push (it needs the lock)" bash -c "! grep -q '^pct push ' '$T/calls.log'"
check "  ...provisioning runs in a clean env with HOME=/root (PVE hooks have none)" grep -qE '^pct exec 1051 -- env -i HOME=/root .*PATH=/root/.local/bin:[^ ]* bash /root/provision-base.sh$' "$T/calls.log"
check "  ...hook output is ASCII-only (PVE task log mangles UTF-8)" bash -c "! LC_ALL=C grep -q '[^ -~]' <<<\"\$1\"" _ "$out"
rm -f "$T/locked/1051"
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
check_sh "GUI pre-start refuses when firewall settings changed since park" '[ $rc -ne 0 ] && grep -q "firewall settings changed" <<<"$out"'
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

echo "== GUI Stop: park deferred until Proxmox releases the CT (#17)"
U=ai-sandbox-park-mistral-1051
gui_stop_hook 1051
check "post-stop under the PVE lock exits 0" [ $STOP_RC -eq 0 ]
[ $STOP_RC -eq 0 ] || echo "$STOP_OUT" | tail -5
check "  ...without pct stop/destroy/create/set/push (they need the lock)" calls_lack '^pct (stop|destroy|create|set|push) '
check "  ...schedules a per-instance park unit via systemd-run" grep -q "^systemd-run --unit $U .* park-deferred mistral 1051\$" "$T/calls.log"
check "  ...and says so in the task log" grep -q 'parking the mistral sandbox (CT 1051) once Proxmox releases it' <<<"$STOP_OUT"
check "  ...nothing parked yet" [ ! -e "$T/state/mistral/pristine-stub" ]
mkdir -p "$T/park-active"; touch "$T/park-active/$U" "$T/locked/1051"
out="$(gui_hook 1051 pre-start)"; rc=$?
check_sh "Start (or Restart's Start half) while the park job runs is refused" '[ $rc -ne 0 ] && grep -q "still being parked.*journalctl -u $U" <<<"$out"'
echo activating > "$T/park-active/$U"
out="$(gui_hook 1051 pre-start)"; rc=$?
check_sh "  ...also while the unit is still activating (Restart's quick pre-start)" '[ $rc -ne 0 ] && grep -q "still being parked" <<<"$out"'
: > "$T/park-active/$U"
rm -f "$T/locked/1051"
out="$(run "$S" status mistral 2>&1)"
check "status says parking is in progress" grep -q 'being parked after GUI Stop' <<<"$out"
( exec 9>/run/lock/ai-sandbox.mistral.lock; flock -n 9; sleep 3 ) &
holder=$!; sleep 0.5
out="$(run "$S" up mistral 2>&1)"; rc=$?
check_sh "up while the park job holds the lock refuses, naming the unit" '[ $rc -ne 0 ] && grep -q "still being parked after a GUI Stop (unit $U)" <<<"$out"'
wait "$holder"
rm -f "$T/park-active/$U"
# the job waits while PVE still has the CT's unit up
touch "$T/unit-active/1051"; ( sleep 3; rm -f "$T/unit-active/1051" ) &
: > "$T/calls.log"; start=$(date +%s)
out="$(run_deferred $U)"; rc=$?
check "park job (env-less, like a unit) exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -5
check "  ...waited for pve-container@1051 to go inactive" [ $(( $(date +%s) - start )) -ge 2 ]
check "  ...clobbered via blkdiscard -f" grep -q '^blkdiscard -f /dev/' "$T/calls.log"
check_sh "  ...parked a fresh stub, marked pristine" '[ "$(cat "$T/state/mistral/pristine-stub" 2>/dev/null)" = 1051 ] && [ ! -e "$T/run/1051" ] && [ -f "$T/conf/1051.conf" ]'
check "  ...says it is ready for GUI Start" grep -q 'parked as a fresh stub - ready for GUI Start' <<<"$out"
touch "$T/locked/1051"
out="$(gui_hook 1051 pre-start)"; rc=$?
check_sh "GUI Start then boots the stub" '[ $rc -eq 0 ] && grep -q "fresh, never-booted stub" <<<"$out"'
rm -f "$T/locked/1051"
# Stop, then the CT is started again before the job runs: leave it alone
touch "$T/run/1051"; gui_stop_hook 1051; touch "$T/run/1051"; : > "$T/calls.log"
out="$(run_deferred $U)"
check_sh "park job leaves a CT that was started meanwhile alone" 'grep -q "started again meanwhile - not parking" <<<"$out" && calls_lack "^pct (stop|destroy|create) "'
rm -f "$T/run/1051"
run_deferred $U >/dev/null   # parks the used CT
: > "$T/calls.log"; out="$(run_deferred $U)"
check_sh "park job is a no-op on an already fresh stub" 'grep -q "already a fresh stub" <<<"$out" && calls_lack "^pct (stop|destroy|create) "'
out="$(run "$S" park-deferred mistral '1051;x' 2>&1)"; rc=$?
check_sh "park-deferred rejects a non-numeric vmid" '[ $rc -ne 0 ] && grep -q "usage: .* park-deferred <agent> <vmid>" <<<"$out"'

echo "== parallel instances (second, fake agent)"
fresh; add_fake_profile
run "$S" up mistral >/dev/null 2>&1
( exec 9>/run/lock/ai-sandbox.mistral.lock; flock -n 9; sleep 5 ) &
holder=$!; sleep 0.5
out="$(run "$S" hook 1051 post-stop 2>&1)"
check "mistral hook passes through while mistral's lock is held" grep -q 'mistral operation in progress - post-stop hook passthrough' <<<"$out"
out="$(run "$S" up fake 2>&1)"; rc=$?
check "fake agent builds while mistral is locked" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -5
check "  ...own CTID/hostname" grep -q '^hostname: ai-sandbox-fake$' "$T/conf/1059.conf"
check "  ...own MAC, different from mistral's" [ "$(cat "$T/state/fake/mac")" != "$(cat "$T/state/mistral/mac")" ]
check "  ...shared keypair reused (one key)" [ "$(ls "$T/state/ssh" | wc -l)" = 2 ]
check "  ...fake policy rendered" grep -q '^mcp=false$' "$T/ct/1059/etc/fake/policy"
rm -f "$T/run/1059"
out="$(run "$S" hook 1059 post-stop 2>&1)"
check_sh "fake post-stop schedules its own park unit while mistral is locked" 'grep -q "parking the fake sandbox (CT 1059)" <<<"$out" && [ -f "$T/deferred/ai-sandbox-park-fake-1059.cmd" ]'
out="$(run_deferred ai-sandbox-park-fake-1059)"
check "  ...and the fake park job parks while mistral is locked" grep -q 'fake sandbox (CT 1059) clobbered and parked' <<<"$out"
wait "$holder"
out="$(run "$S" status 2>&1)"
check_sh "status (all) lists both" 'grep -q "^mistral " <<<"$out" && grep -q "^fake " <<<"$out"'

echo "== tidy-up: ssh, usage, self-update in a git checkout, hook output, apt"
fresh
out="$(run "$S" ssh mistral 2>&1)"
check "ssh refuses when the sandbox is not running" grep -q 'mistral sandbox not running' <<<"$out"
run "$S" up mistral >/dev/null 2>&1
check "up prints the ssh shortcut" bash -c "grep -q 'or on this host: .* ssh mistral' <<<\"\$(cat)\"" < <(run "$S" up mistral 2>&1)
: > "$T/calls.log"
run "$S" ssh mistral uname -a >/dev/null 2>&1
check "ssh <agent> uses the managed key, accept-new, and passes the command" grep -qx "ssh -i $T/state/ssh/ai-sandbox -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new root@192.168.3.77 uname -a" "$T/calls.log"
: > "$T/calls.log"
run AGENT=mistral "$S" ssh >/dev/null 2>&1
check "ssh takes the agent from AGENT= too" grep -qx "ssh -i $T/state/ssh/ai-sandbox -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new root@192.168.3.77" "$T/calls.log"
out="$(run "$S" 2>&1)"
check "usage starts with the description, no shebang or rule lines" bash -c "head -n1 <<<\"\$1\" | grep -q '^ai-sandbox.sh ' && ! grep -qE '^#!|====' <<<\"\$1\"" _ "$out"
check "usage lists ssh" grep -q '^  ssh     <agent>' <<<"$out"
check "provision script disables dpkg progress lines" grep -q 'Dpkg::Use-Pty=0' "$T/ct/1051/root/provision-base.sh"
out="$(run FORCE=1 RESCUE=0 "$S" hook 1051 post-start 2>/dev/null)"
check "hook sends warnings to stdout, in order (PVE task log)" grep -q 'Datacenter firewall is disabled' <<<"$out"
# outside a checkout the self-check tries the network; inside one it must not
out="$(run AUTO_UPDATE=on RAW_URL=http://127.0.0.1:9/none FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check "self-check outside a checkout tries RAW_URL" grep -q 'self-check: could not fetch' <<<"$out"
mkdir "$T/.git"
out="$(run AUTO_UPDATE=on RAW_URL=http://127.0.0.1:9/none FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check "self-check inside a git checkout is skipped" grep -q "self-check: skipped - running from the git checkout at $T" <<<"$out"
check "  ...without touching the network" bash -c "! grep -q 'could not fetch' <<<\"\$1\"" _ "$out"
out="$(run "$S" update 2>&1)"; rc=$?
check_sh "update refuses in a git checkout, pointing at git pull" '[ $rc -ne 0 ] && grep -q "git -C .* pull" <<<"$out"'
rm -rf "$T/.git"

echo "== IPv6: EGRESS_DENY and the public-IPv6 warning"
fresh
V6="2a10:d585:7f66:2:56:1dff:fef2:f487 2a10:d585:7f66:0:56:1dff:fef2:f487"
out="$(run "$S" up mistral 2>&1)"
check "no IPv6 in the sandbox -> no IPv6 warning" bash -c "! grep -q 'public IPv6' <<<\"\$1\"" _ "$out"
out="$(run MOCK_IPV6="$V6" FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check "public IPv6 + lan-block + no EGRESS_DENY -> warning" grep -q 'the mistral sandbox has public IPv6 address' <<<"$out"
check "  ...lists the addresses" grep -q '2a10:d585:7f66:0:56:1dff:fef2:f487/64' <<<"$out"
check "  ...and suggests the /48" grep -q 'EGRESS_DENY=2a10:d585:7f66::/48' <<<"$out"
out="$(run MOCK_IPV6="$V6" EGRESS_DENY=2a10:d585:7f66::/48 FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check "EGRESS_DENY set -> no warning" bash -c "! grep -q 'public IPv6' <<<\"\$1\"" _ "$out"
check "  ...and the .fw drops the site range" grep -q '^OUT DROP -dest 2a10:d585:7f66::/48 -log nolog # EGRESS_DENY' "$T/fw/1051.fw"
check "  ...before the private-range drops" bash -c "[ \$(grep -n 'EGRESS_DENY' '$T/fw/1051.fw' | cut -d: -f1) -lt \$(grep -n '10.0.0.0/8' '$T/fw/1051.fw' | cut -d: -f1) ]"
out="$(run EGRESS_DENY=2a10:d585:7f66::/48 EGRESS_ALLOW=2a10:d585:7f66:2::50/128 FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check "EGRESS_ALLOW still punches a hole first" bash -c "[ \$(grep -n 'EGRESS_ALLOW' '$T/fw/1051.fw' | cut -d: -f1) -lt \$(grep -n 'EGRESS_DENY' '$T/fw/1051.fw' | cut -d: -f1) ]"
out="$(run EGRESS_DENY='2a10::/48;DROP' "$S" up mistral 2>&1)"; rc=$?
check_sh "invalid EGRESS_DENY entry rejected (no .fw injection)" '[ $rc -ne 0 ] && grep -qF "invalid IP/CIDR '\''2a10::/48;DROP'\'' in EGRESS_DENY" <<<"$out"'
out="$(run MOCK_IPV6="$V6" EGRESS_POLICY=strict FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check "strict policy (drops everything) -> no IPv6 warning" bash -c "! grep -q 'public IPv6' <<<\"\$1\"" _ "$out"

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

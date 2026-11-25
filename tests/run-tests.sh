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
  env PATH="$HERE/bin:$PATH" HOME="$T/home" STATE_DIR="$T/state" FW_DIR="$T/fw" PVE_LXC_DIR="$T/conf" SYSTEMD_UNIT_DIR="$T/units" \
      HOOK_SNIPPET_DIR="$T/snip" AUTO_UPDATE=off TEMPLATE=local:vztmpl/debian-12.tar.zst \
      EXPORT_DIR="$T/export" "$@"
}
calls_lack() { ! grep -qE "$1" "$T/calls.log"; }
origin_of() { cat "$T/lvorigin/vm-$1-disk-0" 2>/dev/null; }   # lvmthin: a linked clone's LVM origin
hookvars() {   # what reaches an env-less hook or systemd unit: the config, not your shell
  echo "STATE_DIR=$T/state FW_DIR=$T/fw PVE_LXC_DIR=$T/conf HOOK_SNIPPET_DIR=$T/snip AUTO_UPDATE=off TEMPLATE=local:vztmpl/d.tar.zst"
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
profile_fake_credential_paths() { echo /root/.fake/env; }
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
check "  ...and names known agents" grep -q 'known agents: claude deepseek gemini mistral' <<<"$out"
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
  env -i PATH="$HERE/bin:/usr/bin:/bin" MOCK_T="$T" bash -c "STATE_DIR=$T/state FW_DIR=$T/fw PVE_LXC_DIR=$T/conf HOOK_SNIPPET_DIR=$T/snip AUTO_UPDATE=off TEMPLATE=local:vztmpl/d.tar.zst $S hook $1 $2" 2>&1
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
check "  ...provisioning runs in a clean env with HOME=/root (PVE hooks have none)" grep -qE '^lxc-attach -n 1051 --clear-env -- env -i HOME=/root .*PATH=/root/.local/bin:[^ ]* bash /root/provision-base.sh$' "$T/calls.log"
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
out="$(gui_hook_fw_off() { env -i PATH="$HERE/bin:/usr/bin:/bin" MOCK_T="$T" bash -c "FIREWALL=off STATE_DIR=$T/state FW_DIR=$T/fw PVE_LXC_DIR=$T/conf HOOK_SNIPPET_DIR=$T/snip AUTO_UPDATE=off $S hook 1051 pre-start" 2>&1; }; gui_hook_fw_off)"; rc=$?
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

echo "== provisioned marker: failed provisioning is visible (#15)"
fresh
out="$(run "$S" up mistral 2>&1)"
check "after a good up: provisioned marker for CT 1051" [ "$(cat "$T/state/mistral/provisioned" 2>/dev/null)" = 1051 ]
check_sh "  ...and no failure line" '! grep -q "provisioning FAILED" <<<"$out"'
out="$(run "$S" status mistral 2>&1)"
check "status: running, provisioned" grep -q '^mistral: CT 1051 running, provisioned, ip: 192.168.3.77' <<<"$out"
out="$(run "$S" status 2>&1)"
check "status (all): PROVISIONED yes" grep -qE '^mistral +1051 +running +192\.168\.3\.77 +yes$' <<<"$out"
rm -f "$T/state/mistral/provisioned"
( exec 9>/run/lock/ai-sandbox.mistral.lock; flock -n 9; sleep 3 ) &
holder=$!; sleep 0.5
out="$(run "$S" status mistral 2>&1)"
check "no marker while the agent's lock is held: provisioning in progress" grep -q 'running, provisioning in progress' <<<"$out"
wait "$holder"
run "$S" up mistral >/dev/null 2>&1
run FORCE=1 RESCUE=0 "$S" down mistral >/dev/null 2>&1
check "down clears the marker" [ ! -e "$T/state/mistral/provisioned" ]
# GUI Start whose post-start provisioning fails: PVE still says TASK OK
mkdir -p "$T/locked"; touch "$T/locked/1051"
gui_hook 1051 pre-start >/dev/null
rm -f "$T/locked/1051"; touch "$T/run/1051"
out="$(env -i PATH="$HERE/bin:/usr/bin:/bin" MOCK_T="$T" MOCK_PROVISION_FAIL=1 bash -c "$(hookvars) $S hook 1051 post-start" 2>&1)"; rc=$?
check_sh "GUI post-start with failing provisioning ends on a FAILED line" '[ $rc -ne 0 ] && tail -n1 <<<"$out" | grep -q "^post-start: provisioning FAILED (exit 127) - the mistral sandbox is NOT ready"'
check_sh "  ...after the real error, not instead of it" 'grep -q "vibe: command not found" <<<"$out"'
check_sh "  ...and never claims ready" '! grep -q "ready via GUI" <<<"$out"'
check "  ...no marker" [ ! -e "$T/state/mistral/provisioned" ]
out="$(run "$S" status mistral 2>&1)"
check "  ...status: running, NOT provisioned, pointing at up" grep -q "running, NOT provisioned (see the Start task log, or run '.* up mistral')" <<<"$out"
out="$(run "$S" status 2>&1)"
check "  ...status (all): PROVISIONED NO" grep -qE '^mistral +1051 +running +192\.168\.3\.77 +NO$' <<<"$out"
out="$(run MOCK_PROVISION_FAIL=1 FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"; rc=$?
check_sh "CLI up with failing provisioning exits non-zero, FAILED line last" '[ $rc -ne 0 ] && tail -n1 <<<"$out" | grep -q "^up: provisioning FAILED (exit 127)"'
check "  ...no marker" [ ! -e "$T/state/mistral/provisioned" ]
out="$(run FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"; rc=$?
check_sh "a good up afterwards: provisioned again, no FAILED line" '[ $rc -eq 0 ] && [ "$(cat "$T/state/mistral/provisioned")" = 1051 ] && ! grep -q "provisioning FAILED" <<<"$out"'

echo "== bake: golden template in two alternating slots (#9a)"
fresh
printf 'dir: local\n\tpath /var/lib/vz\n\tcontent vztmpl,backup\n\nlvmthin: local-lvm\n\tthinpool data\n\tcontent rootdir,images\n' > "$T/storage.cfg"
B() { run STORAGE_CFG="$T/storage.cfg" "$@"; }
out="$(B STORAGE=local "$S" bake 2>&1)"; rc=$?
check_sh "bake refuses storage that cannot hold linked clones" '[ $rc -ne 0 ] && grep -q "storage .local. (type .dir.*cannot hold linked clones" <<<"$out"'
out="$(B GOLDEN_CTIDS=1051,1049 "$S" bake 2>&1)"; rc=$?
check_sh "bake refuses a golden slot that is an agent's CTID" '[ $rc -ne 0 ] && grep -q "golden CT ID 1051 collides" <<<"$out"'
out="$(B BAKE_AGENTS=bogus "$S" bake 2>&1)"; rc=$?
check_sh "bake refuses an unknown agent in BAKE_AGENTS" '[ $rc -ne 0 ] && grep -q "unknown agent .bogus. in BAKE_AGENTS" <<<"$out"'
: > "$T/calls.log"
out="$(B "$S" bake 2>&1)"; rc=$?
check "first bake exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -8
G="$T/conf/1048.conf"
check "  ...builds in slot 1048 as ai-sandbox-golden" grep -q '^hostname: ai-sandbox-golden$' "$G"
check "  ...tagged ai-sandbox;golden" grep -q '^tags: ai-sandbox;golden$' "$G"
check "  ...is a template now, stopped" grep -q '^template: 1$' "$G"
check_sh "  ...without a hookscript or pinned MAC" '! grep -qE "^hookscript:|hwaddr=" "$G"'
check "  ...installs the baseline + every agent CLI, then verifies" grep -q 'curl -LsSf https://mistral.ai/vibe/install.sh | bash' "$T/ct/1048/root/provision-base.sh"
check "  ...provision script is valid bash" bash -n "$T/ct/1048/root/provision-base.sh"
check "  ...strips SSH host keys, machine-id, authorized_keys" grep -qF 'rm -f /etc/ssh/ssh_host_*' "$T/calls.log"
check "  ...and makes clones generate their own host keys at boot" grep -qF 'ExecStartPre=/usr/bin/ssh-keygen -A' "$T/calls.log"
check "  ...checks every credential path" grep -q 'lxc-attach -n 1048 --clear-env -- env -i .* test -e /root/.vibe/.env$' "$T/calls.log"
check_sh "  ...never injects a credential or policy" '! grep -q "/root/.vibe/.env\|config.toml" <(find "$T/ct/1048" -type f)'
check "  ...stamps the image" grep -q '^baked=.* ctid=1048 agents=claude,deepseek,gemini,mistral$' "$T/ct/1048/etc/ai-sandbox-golden"
check "  ...with every agent's CLI (BAKE_AGENTS=all)" grep -q 'curl -fsSL https://claude.ai/install.sh | bash' "$T/ct/1048/root/provision-base.sh"
check_sh "  ...installing a CLI two profiles share (claude, deepseek) once" '[ "$(grep -c "claude.ai/install.sh" "$T/ct/1048/root/provision-base.sh")" = 1 ] && grep -q "same installer as an agent above" "$T/ct/1048/root/provision-base.sh"'
check "  ...records it as current on the host" [ "$(cat "$T/state/golden/current")" = 1048 ]
check "  ...build-time firewall removed (the template never runs)" [ ! -e "$T/fw/1048.fw" ]
check_sh "  ...stop happens before template" '[ $(grep -n "^pct stop 1048" "$T/calls.log" | cut -d: -f1) -lt $(grep -n "^pct template 1048" "$T/calls.log" | cut -d: -f1) ]'
out="$(run "$S" status 2>&1)"
check_sh "status lists the golden as a template, not as an agent" 'grep -q "^golden: CT 1048 template (current), baked=" <<<"$out" && ! grep -qE "^golden +1048" <<<"$out"'
out="$(run "$S" hook 1048 pre-start 2>&1)"; rc=$?
check_sh "hook ignores the golden CT" '[ $rc -eq 0 ] && [ -z "$out" ]'
out="$(run "$S" up golden 2>&1)"; rc=$?
check_sh "'golden' is not an agent" '[ $rc -ne 0 ] && grep -q "unknown agent .golden." <<<"$out"'
out="$(B "$S" bake 2>&1)"; rc=$?
check_sh "second bake goes to slot 1049 and leaves 1048 alone" '[ $rc -eq 0 ] && [ "$(cat "$T/state/golden/current")" = 1049 ] && grep -q "^template: 1$" "$T/conf/1048.conf" && grep -q "^template: 1$" "$T/conf/1049.conf"'
check "  ...says the previous golden is kept" grep -q 'previous golden CT 1048 is kept' <<<"$out"
# a sandbox still runs from 1048: the third bake must not destroy it
printf 'hostname: ai-sandbox-mistral\ntags: ai-sandbox\nrootfs: local-lvm:base-1048-disk-0/vm-1051-disk-0,size=40G\n' > "$T/conf/1051.conf"
: > "$T/calls.log"
out="$(B "$S" bake 2>&1)"; rc=$?
check_sh "third bake refuses while slot 1048 backs a linked clone" '[ $rc -ne 0 ] && grep -q "CT 1048 still backs linked clone(s): 1051" <<<"$out"'
check_sh "  ...destroying nothing, current still 1049" 'calls_lack "^pct (destroy|create) " && [ "$(cat "$T/state/golden/current")" = 1049 ]'
out="$(run "$S" status 2>&1)"
check "status shows the previous golden's clones" grep -q '^golden: CT 1048 template (previous), linked clones: 1051' <<<"$out"
rm -f "$T/conf/1051.conf"
: > "$T/calls.log"
out="$(B "$S" bake 2>&1)"; rc=$?
check_sh "once 1048 is free, the third bake rebuilds it" '[ $rc -eq 0 ] && grep -q "^pct destroy 1048" "$T/calls.log" && [ "$(cat "$T/state/golden/current")" = 1048 ]'
check "  ...and never touches the current one (1049)" calls_lack '^pct (destroy|stop|create) 1049'
# a credential in the image: fail closed, keep the current golden
out="$(B MOCK_LEAK_PATH=/root/.vibe/.env "$S" bake 2>&1)"; rc=$?
check_sh "a credential path in the image fails the bake" '[ $rc -ne 0 ] && grep -q "credential path(s) present in the golden image" <<<"$out" && grep -q "mistral: /root/.vibe/.env" <<<"$out"'
check_sh "  ...the build CT is not templated, current unchanged" '! grep -q "^template: 1$" "$T/conf/1049.conf" && [ "$(cat "$T/state/golden/current")" = 1048 ]'
check "  ...and the failure line says so" grep -q 'bake: FAILED (exit 1) - CT 1049 was not templated; the current golden (CT 1048) is unchanged' <<<"$out"
out="$(run "$S" status 2>&1)"
check "status flags the half-built slot" grep -q '^golden: CT 1049 NOT a template' <<<"$out"
out="$(B "$S" bake 2>&1)"; rc=$?
check_sh "the next bake replaces the half-built CT" '[ $rc -eq 0 ] && grep -q "^template: 1$" "$T/conf/1049.conf" && [ "$(cat "$T/state/golden/current")" = 1049 ]'
printf 'hostname: wordpress\ntags: web\n' > "$T/conf/1048.conf"
out="$(B "$S" bake 2>&1)"; rc=$?
check_sh "a foreign CT in a golden slot is never destroyed" '[ $rc -ne 0 ] && grep -q "refusing to touch CT 1048" <<<"$out" && grep -q wordpress "$T/conf/1048.conf"'

echo "== spawn: sessions as linked clones of the golden (#9b)"
fresh
printf 'lvmthin: local-lvm\n\tthinpool data\n\tvgname pve\n\tcontent rootdir,images\n' > "$T/storage.cfg"
B() { run STORAGE_CFG="$T/storage.cfg" "$@"; }
out="$(B "$S" up mistral 2>&1)"; rc=$?
check_sh "no golden yet, MODE=auto: full rebuild with a note" '[ $rc -eq 0 ] && grep -q "MODE=auto: no golden template yet .* full rebuild instead" <<<"$out" && grep -q "^pct create 1051 " "$T/calls.log"'
out="$(B "$S" status mistral 2>&1)"
check "  ...status: built from a full rebuild" grep -q '^  built from: full rebuild$' <<<"$out"
out="$(B MODE=clone FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"; rc=$?
check_sh "no golden + MODE=clone refuses instead of rebuilding" '[ $rc -ne 0 ] && grep -q "MODE=clone: no golden template yet" <<<"$out"'
out="$(B MODE=sideways "$S" up mistral 2>&1)"; rc=$?
check_sh "invalid MODE rejected" '[ $rc -ne 0 ] && grep -q "invalid MODE=.sideways." <<<"$out"'
B FORCE=1 RESCUE=0 "$S" down mistral >/dev/null 2>&1   # a full-build stub, parked before any bake
out="$(B "$S" bake 2>&1)"; rc=$?
check "bake exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -8
check_sh "  ...and moves the pristine full-build stub onto the golden" 'grep -q "refresh: re-parking the mistral stub (CT 1051) onto golden CT 1048" <<<"$out" && [ "$(origin_of 1051)" = base-1048-disk-0 ] && [ -e "$T/state/mistral/pristine-stub" ]'
: > "$T/calls.log"
out="$(B FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"; rc=$?
check "up after a bake exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -8
check "  ...as a linked clone of the golden" grep -q '^pct clone 1048 1051 --hostname ai-sandbox-mistral --full 0$' "$T/calls.log"
check "  ...not a full build" calls_lack '^pct create 1051 '
# shellcheck disable=SC2034  # used inside check_sh strings, which ShellCheck cannot see
C1="$T/conf/1051.conf"
check_sh "  ...with this instance's settings: tag, hookscript, pinned MAC + firewall" 'grep -q "^tags: ai-sandbox$" "$C1" && grep -q "^hookscript: local:snippets/ai-sandbox-hook.sh$" "$C1" && grep -qE "^net0: .*hwaddr=$(cat "$T/state/mistral/mac"),firewall=1" "$C1"'
check_sh "  ...and none of the golden's identity" '! grep -qE "^template:|golden" "$C1" && grep -q "^hostname: ai-sandbox-mistral$" "$C1"'
check "  ...started after the settings were applied" bash -c "[ \$(grep -n '^pct set 1051 ' '$T/calls.log' | head -n1 | cut -d: -f1) -lt \$(grep -n '^pct start 1051' '$T/calls.log' | cut -d: -f1) ]"
check "  ...skips the baseline/CLI provisioning (baked in)" calls_lack 'bash /root/provision-base.sh'
check_sh "  ...regenerates SSH host keys in the CT" 'grep -q "^lxc-attach -n 1051 --clear-env -- env -i .* bash -c set -e$" "$T/calls.log" && grep -qx "ssh-keygen -A >/dev/null" "$T/calls.log"'
check_sh "  ...clears the start-rate limit and insists sshd runs" 'grep -q "^systemctl reset-failed ssh" "$T/calls.log" && grep -qx "systemctl restart ssh" "$T/calls.log" && grep -q "^systemctl is-active --quiet ssh" "$T/calls.log"'
check_sh "  ...pushes root's authorized key" 'cmp -s "$T/state/ssh/ai-sandbox.pub" "$T/ct/1051/root/.ssh/authorized_keys"'
check_sh "  ...injects the policy and marks it provisioned" '[ -f "$T/ct/1051/root/.vibe/config.toml" ] && [ "$(cat "$T/state/mistral/provisioned")" = 1051 ]'
check "  ...prints the ssh line" grep -q 'sandbox ready.' <<<"$out"
check "  ...with no read-only pct/pveam/pvesm calls (each ~2.5 s of Perl on pve1)" calls_lack '^(pct (config|status|list|exec|push)|pveam|pvesm) '
check_sh "  ...only the writes go through pct" '[ "$(grep -cE "^pct " "$T/calls.log")" -le 6 ]'
check "  ...its rootfs is a plain lvmthin volume (as on pve1)" grep -q '^rootfs: local-lvm:vm-1051-disk-0,' "$C1"
check_sh "  ...and the host-side firewall ruleset survives pct clone" 'grep -q "^# ai-sandbox managed firewall (CT 1051" "$T/fw/1051.fw" && grep -q "OUT DROP -dest 192.168.0.0/16" "$T/fw/1051.fw"'
check_sh "  ...rewritten after the clone, before the start" '[ $(grep -n "^pct clone 1048 1051" "$T/calls.log" | cut -d: -f1) -lt $(grep -n "^pct start 1051" "$T/calls.log" | cut -d: -f1) ]'
check_sh "  ...summary reports it active, not missing" 'grep -q "hardening: firewall=lan-block (pending Datacenter firewall)" <<<"$out"'
out="$(B "$S" status mistral 2>&1)"
check "status: built from golden CT 1048 (current)" grep -q '^  built from: golden CT 1048 (current)$' <<<"$out"
out="$(B MOCK_CLONE_STYLE=zfs FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check_sh "zfs-style clone volume (base-N/...) is recognised too" 'grep -q "^rootfs: local-zfs:base-1048-disk-0/subvol-1051" "$C1" && calls_lack "bash /root/provision-base.sh" && [ -f "$T/fw/1051.fw" ]'
out="$(B MOCK_SSHD_FAIL=1 FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"; rc=$?
check_sh "sshd that will not start fails the spawn loudly, not provisioned" '[ $rc -ne 0 ] && grep -q "spawn: sshd did not start in CT 1051" <<<"$out" && grep -q "up: provisioning FAILED" <<<"$out" && [ ! -e "$T/state/mistral/provisioned" ]'
out="$(B DISK_GB=60 FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check "DISK_GB above the golden's size grows the clone" grep -q '^pct resize 1051 rootfs 60G$' "$T/calls.log"
out="$(B DISK_GB=20 FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check "DISK_GB below it is noted, not attempted" grep -q 'cannot shrink, keeping 40G' <<<"$out"
: > "$T/calls.log"
out="$(B TOPUP=on FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check_sh "TOPUP=on re-runs only the agent installer on the clone" 'grep -q "TOPUP=on" <<<"$out" && grep -q "curl -LsSf https://mistral.ai/vibe/install.sh | bash" "$T/ct/1051/root/topup.sh" && ! grep -q "apt-get" "$T/ct/1051/root/topup.sh" && grep -q "bash /root/topup.sh" "$T/calls.log"'
: > "$T/calls.log"
out="$(B MODE=rebuild FORCE=1 RESCUE=0 "$S" up mistral 2>&1)"
check_sh "MODE=rebuild still does the full build" 'grep -q "^pct create 1051 " "$T/calls.log" && calls_lack "^pct clone " && grep -q "bash /root/provision-base.sh" "$T/calls.log"'
# GUI lifecycle on clones: down parks a clone stub; Start provisions it env-less
B FORCE=1 RESCUE=0 "$S" up mistral >/dev/null 2>&1
: > "$T/calls.log"
out="$(B FORCE=1 RESCUE=0 "$S" down mistral 2>&1)"
check_sh "down parks a never-started clone stub" 'grep -q "^pct clone 1048 1051 " "$T/calls.log" && calls_lack "^pct start 1051" && [ -e "$T/state/mistral/pristine-stub" ] && [ ! -e "$T/run/1051" ]'
mkdir -p "$T/locked"; touch "$T/locked/1051"
out="$(gui_hook 1051 pre-start)"; rc=$?
check "GUI pre-start boots the clone stub" [ $rc -eq 0 ]
rm -f "$T/locked/1051"; touch "$T/run/1051"; : > "$T/calls.log"
out="$(env -i PATH="$HERE/bin:/usr/bin:/bin" MOCK_T="$T" bash -c "$(hookvars) $S hook 1051 post-start" 2>&1)"; rc=$?
check_sh "GUI post-start (no shell env) does spawn provisioning" '[ $rc -eq 0 ] && grep -q "ready via GUI" <<<"$out" && grep -q "ssh-keygen -A" "$T/calls.log" && calls_lack "bash /root/provision-base.sh"'
check "  ...with the managed key (hooks never run shared_setup)" cmp -s "$T/state/ssh/ai-sandbox.pub" "$T/ct/1051/root/.ssh/authorized_keys"
# a second bake: the running clone stays on 1048, stubs move to 1049
add_fake_profile
B "$S" up fake >/dev/null 2>&1
B FORCE=1 RESCUE=0 "$S" down fake >/dev/null 2>&1
check "the fake agent is not in the golden: its stub is a full build" grep -q '^rootfs: local-lvm:' "$T/conf/1059.conf"
out="$(B BAKE_AGENTS=mistral,fake "$S" bake 2>&1)"; rc=$?
out2="$(B "$S" status 2>&1)"
check "status (all) sees the lvmthin clone of the previous golden" grep -q '^golden: CT 1048 template (previous), linked clones: 1051' <<<"$out2"
check_sh "second bake (both agents) goes to 1049" '[ $rc -eq 0 ] && [ "$(cat "$T/state/golden/current")" = 1049 ]'
check_sh "  ...the running mistral clone is left on 1048" '[ "$(origin_of 1051)" = base-1048-disk-0 ] && [ -e "$T/run/1051" ]'
check_sh "  ...the fake stub moves onto 1049" '[ "$(origin_of 1059)" = base-1049-disk-0 ] && [ -e "$T/state/fake/pristine-stub" ]'
out="$(B "$S" status mistral 2>&1)"
check "status flags the previous golden" grep -q 'built from: golden CT 1048 (previous; the next park or up moves it' <<<"$out"
: > "$T/calls.log"
out="$(B "$S" bake 2>&1)"; rc=$?
check_sh "a bake now refuses: slot 1048 backs the running lvmthin clone 1051" '[ $rc -ne 0 ] && grep -q "CT 1048 still backs linked clone(s): 1051" <<<"$out" && calls_lack "^pct destroy 1048"'
B FORCE=1 RESCUE=0 "$S" up mistral >/dev/null 2>&1
check_sh "the next up moves mistral to the current golden" '[ "$(origin_of 1051)" = base-1049-disk-0 ]'
out="$(B "$S" bake 2>&1)"; rc=$?
check_sh "so the third bake can reuse slot 1048" '[ $rc -eq 0 ] && [ "$(cat "$T/state/golden/current")" = 1048 ]'

echo "== weekly bake timer (#9c)"
fresh
out="$(run "$S" timer 2>&1)"
check "timer with no units: off, with a hint" grep -q 'bake timer: off (turn it on with: .* timer on)' <<<"$out"
: > "$T/calls.log"
out="$(run "$S" timer on 2>&1)"; rc=$?
check "timer on exits 0" [ $rc -eq 0 ]
check_sh "  ...service runs this script's bake, oneshot" 'grep -qx "ExecStart=$S bake" "$T/units/ai-sandbox-bake.service" && grep -qx "Type=oneshot" "$T/units/ai-sandbox-bake.service"'
check_sh "  ...timer: weekly default, persistent, jittered" 'grep -qx "OnCalendar=Sun \*-\*-\* 03:00:00" "$T/units/ai-sandbox-bake.timer" && grep -qx "Persistent=true" "$T/units/ai-sandbox-bake.timer" && grep -qx "RandomizedDelaySec=30min" "$T/units/ai-sandbox-bake.timer"'
check_sh "  ...reloaded and enabled" 'grep -qx "systemctl daemon-reload" "$T/calls.log" && grep -qx "systemctl enable --now ai-sandbox-bake.timer" "$T/calls.log"'
out="$(run "$S" timer 2>&1)"
check_sh "timer shows schedule and next run" 'grep -q "^bake timer: on (Sun \*-\*-\* 03:00:00)" <<<"$out" && grep -q "ai-sandbox-bake.timer" <<<"$out"'
check "  ...and a bake that never ran as 'never run yet', not 'success'" grep -q 'last bake: never run yet' <<<"$out"
echo exit-code > "$T/bake-ran"
out="$(run "$S" timer 2>&1)"
check "  ...and a failed last bake as failed, with when" grep -q 'last bake: exit-code (started Sun 2026-11-29 03:21:18 GMT)' <<<"$out"
rm -f "$T/bake-ran"
out="$(run "$S" status 2>&1)"
check "status (all) mentions the timer" grep -q '^bake timer: on (Sun \*-\*-\* 03:00:00) - details: .* timer' <<<"$out"
printf 'BAKE_SCHEDULE="Wed *-*-* 02:30:00"\n' > "$T/state/config.env"
run "$S" timer on >/dev/null 2>&1
check "BAKE_SCHEDULE from the config file" grep -qx 'OnCalendar=Wed \*-\*-\* 02:30:00' "$T/units/ai-sandbox-bake.timer"
out="$(run BAKE_SCHEDULE='weekly
ExecStartPre=/bin/evil' "$S" timer on 2>&1)"; rc=$?
check_sh "a schedule that would inject unit lines is refused" '[ $rc -ne 0 ] && grep -q "invalid BAKE_SCHEDULE" <<<"$out" && ! grep -q evil "$T/units/ai-sandbox-bake.timer"'
out="$(run BAKE_SCHEDULE='not a date' "$S" timer on 2>&1)"; rc=$?
check_sh "an unparseable schedule is refused (systemd-analyze)" '[ $rc -ne 0 ] || ! command -v systemd-analyze >/dev/null'
: > "$T/calls.log"
out="$(run "$S" timer off 2>&1)"; rc=$?
check_sh "timer off disables and removes both units" '[ $rc -eq 0 ] && grep -qx "systemctl disable --now ai-sandbox-bake.timer" "$T/calls.log" && [ ! -e "$T/units/ai-sandbox-bake.timer" ] && [ ! -e "$T/units/ai-sandbox-bake.service" ]'
printf '[Timer]\nOnCalendar=daily\n' > "$T/units/ai-sandbox-bake.timer"
out="$(run "$S" timer on 2>&1)"; rc=$?
check_sh "a unit file not written by the script is never overwritten" '[ $rc -ne 0 ] && grep -q "refusing to overwrite" <<<"$out" && grep -qx "OnCalendar=daily" "$T/units/ai-sandbox-bake.timer"'
out="$(run "$S" timer off 2>&1)"; rc=$?
check_sh "...or removed" '[ $rc -ne 0 ] && grep -q "refusing to remove" <<<"$out" && [ -e "$T/units/ai-sandbox-bake.timer" ]'

echo "== claude profile (#10)"
fresh
out="$(run "$S" agents)"
check "agents lists claude with CT 1052" grep -q 'claude *CT 1052 *Claude Code' <<<"$out"
out="$(run "$S" up claude 2>&1)"; rc=$?
check "up claude without secrets exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -8
check "  ...and explains both credential kinds" bash -c 'grep -q "ANTHROPIC_API_KEY=" <<<"$1" && grep -q "claude setup-token" <<<"$1" && grep -q "CLAUDE_CODE_OAUTH_TOKEN=" <<<"$1"' _ "$out"
check_sh "  ...own CT, hostname, native installer, verify" 'grep -q "^hostname: ai-sandbox-claude$" "$T/conf/1052.conf" && grep -q "curl -fsSL https://claude.ai/install.sh | bash" "$T/ct/1052/root/provision-base.sh" && [ "$(tail -n1 "$T/ct/1052/root/provision-base.sh")" = "claude --version" ]'
check_sh "  ...and no Vibe in its build" '! grep -q "mistral.ai/vibe" "$T/ct/1052/root/provision-base.sh"'
M="$T/ct/1052/etc/claude-code/managed-settings.json"
check "managed settings injected" [ -f "$M" ]
check "  ...mode 444" [ "$(stat -c %a "$M")" = 444 ]
check_sh "  ...valid JSON with every default-deny key" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"permissions\"][\"disableBypassPermissionsMode\"]==\"disable\" and d[\"disableAutoMode\"]==\"disable\" and d[\"disableClaudeAiConnectors\"] is True and d[\"allowedMcpServers\"]==[] and d[\"enableAllProjectMcpServers\"] is False" "$M"'
out="$(run AGENT_MCP=on FORCE=1 RESCUE=0 "$S" up claude 2>&1)"
check_sh "AGENT_MCP=on drops only the MCP keys" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert \"allowedMcpServers\" not in d and \"enableAllProjectMcpServers\" not in d and d[\"disableClaudeAiConnectors\"] is True and \"permissions\" in d" "$M"'
out="$(run AGENT_MCP=on AGENT_CONNECTORS=on AGENT_AUTO_APPROVE=on FORCE=1 RESCUE=0 "$S" up claude 2>&1)"
check_sh "all three on: an empty (valid) policy" 'python3 -c "import json,sys; assert json.load(open(sys.argv[1]))=={}" "$M"'
mkdir -p "$T/state/claude"; printf 'CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-test_not-real"\n' > "$T/state/claude/secrets.env"; chmod 600 "$T/state/claude/secrets.env"
out="$(run FORCE=1 RESCUE=0 "$S" up claude 2>&1)"; rc=$?
U="$T/ct/1052/root/.claude/settings.json"
check_sh "subscription token -> settings.json env block, mode 600" '[ $rc -eq 0 ] && [ "$(stat -c %a "$U")" = 600 ] && python3 -c "import json,sys; assert json.load(open(sys.argv[1]))=={\"env\":{\"CLAUDE_CODE_OAUTH_TOKEN\":\"sk-ant-oat01-test_not-real\"}}" "$U"'
printf 'ANTHROPIC_API_KEY=sk-ant-api03-key\nCLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-tok\n' > "$T/state/claude/secrets.env"
out="$(run FORCE=1 RESCUE=0 "$S" up claude 2>&1)"; rc=$?
check_sh "both set: both passed, with a precedence warning, valid JSON" '[ $rc -eq 0 ] && grep -q "uses ANTHROPIC_API_KEY first" <<<"$out" && python3 -c "import json,sys; d=json.load(open(sys.argv[1]))[\"env\"]; assert d[\"ANTHROPIC_API_KEY\"]==\"sk-ant-api03-key\" and d[\"CLAUDE_CODE_OAUTH_TOKEN\"]==\"sk-ant-oat01-tok\"" "$U"'
printf 'ANTHROPIC_API_KEY=sk-ant-api03-"x","y":"$(touch %s/pwned)\n' "$T" > "$T/state/claude/secrets.env"
out="$(run FORCE=1 RESCUE=0 "$S" up claude 2>&1)"; rc=$?
check_sh "a value with JSON/shell metacharacters is refused, never executed" '[ $rc -ne 0 ] && grep -q "has characters a key or token never contains" <<<"$out" && [ ! -e "$T/pwned" ]'
printf 'SOMETHING_ELSE=1\n' > "$T/state/claude/secrets.env"
out="$(run FORCE=1 RESCUE=0 "$S" up claude 2>&1)"; rc=$?
check_sh "a secrets file without either key fails clearly" '[ $rc -ne 0 ] && grep -q "no ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN line" <<<"$out"'
out="$(run "$S" export claude 2>&1)"
check "export suggests the Claude Code VS Code extension" grep -q 'anthropic.claude-code' <<<"$out"
out="$(run "$S" status 2>&1)"
check "status (all) lists claude" grep -qE '^claude +1052 +running' <<<"$out"

echo "== gemini profile (#11)"
fresh
out="$(run "$S" agents)"
check "agents lists gemini with CT 1053" grep -q 'gemini *CT 1053 *Gemini CLI' <<<"$out"
out="$(run "$S" up gemini 2>&1)"; rc=$?
check "up gemini without secrets exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -8
check "  ...with the AI Studio hint" grep -q 'aistudio.google.com' <<<"$out"
P="$T/ct/1053/root/provision-base.sh"
check_sh "  ...Node >= 20 from NodeSource only when missing or too old, then the npm package" 'grep -q "process.versions.node.split" "$P" && grep -q "deb.nodesource.com/setup_22.x" "$P" && grep -q "npm install -g --no-fund --no-audit @google/gemini-cli" "$P" && [ "$(tail -n1 "$P")" = "gemini --version" ]'
check "  ...provision script is valid bash" bash -n "$P"
check_sh "  ...and installs the key launcher (folder trust blocks ~/.gemini/.env)" 'grep -q "GEMINI_API_KEY from ~/.gemini/.env, also in untrusted folders" "$P" && grep -q "> /usr/local/bin/gemini" "$P"'
G="$T/ct/1053/etc/gemini-cli/settings.json"
check "system settings injected, mode 444" [ "$(stat -c %a "$G" 2>/dev/null)" = 444 ]
check_sh "  ...valid JSON, every default-deny key" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); s=d[\"security\"]; a=d[\"admin\"]; assert s[\"disableYoloMode\"] is True and s[\"disableAlwaysAllow\"] is True and s[\"blockGitExtensions\"] is True and a[\"secureModeEnabled\"] is True and a[\"mcp\"][\"enabled\"] is False and a[\"extensions\"][\"enabled\"] is False and d[\"mcp\"][\"allowed\"]==[]" "$G"'
out="$(run AGENT_MCP=on FORCE=1 RESCUE=0 "$S" up gemini 2>&1)"
check_sh "AGENT_MCP=on drops only the MCP keys" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert \"mcp\" not in d and \"mcp\" not in d[\"admin\"] and d[\"admin\"][\"extensions\"][\"enabled\"] is False and d[\"security\"][\"disableYoloMode\"] is True" "$G"'
out="$(run AGENT_AUTO_APPROVE=on AGENT_CONNECTORS=on FORCE=1 RESCUE=0 "$S" up gemini 2>&1)"
check_sh "only MCP off: no security block, admin holds just mcp" 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert \"security\" not in d and d[\"admin\"]=={\"mcp\":{\"enabled\":False}} and d[\"mcp\"]=={\"allowed\":[]}" "$G"'
out="$(run AGENT_MCP=on AGENT_CONNECTORS=on AGENT_AUTO_APPROVE=on FORCE=1 RESCUE=0 "$S" up gemini 2>&1)"
check_sh "all three on: an empty (valid) policy" 'python3 -c "import json,sys; assert json.load(open(sys.argv[1]))=={}" "$G"'
mkdir -p "$T/state/gemini"; printf "GEMINI_API_KEY='AIzaSy-test_not.real'\n" > "$T/state/gemini/secrets.env"; chmod 600 "$T/state/gemini/secrets.env"
out="$(run FORCE=1 RESCUE=0 "$S" up gemini 2>&1)"; rc=$?
# shellcheck disable=SC2034  # used inside check_sh strings
E="$T/ct/1053/root/.gemini/.env"
check_sh "key -> ~/.gemini/.env (600), quotes stripped" '[ $rc -eq 0 ] && [ "$(cat "$E")" = "GEMINI_API_KEY=AIzaSy-test_not.real" ] && [ "$(stat -c %a "$E")" = 600 ]'
check_sh "  ...and user settings select API-key auth (valid JSON)" 'python3 -c "import json,sys; assert json.load(open(sys.argv[1]))[\"security\"][\"auth\"][\"selectedType\"]==\"gemini-api-key\"" "$T/ct/1053/root/.gemini/settings.json"'
printf 'GEMINI_API_KEY=abc$(touch %s/pwned)\n' "$T" > "$T/state/gemini/secrets.env"
out="$(run FORCE=1 RESCUE=0 "$S" up gemini 2>&1)"; rc=$?
check_sh "a key with shell metacharacters is refused, never executed" '[ $rc -ne 0 ] && grep -q "has characters a key never contains" <<<"$out" && [ ! -e "$T/pwned" ]'
printf 'OTHER=1\n' > "$T/state/gemini/secrets.env"
out="$(run FORCE=1 RESCUE=0 "$S" up gemini 2>&1)"; rc=$?
check_sh "a secrets file without GEMINI_API_KEY fails clearly" '[ $rc -ne 0 ] && grep -q "no GEMINI_API_KEY line" <<<"$out"'
rm -f "$T/state/gemini/secrets.env"; run FORCE=1 RESCUE=0 "$S" up gemini >/dev/null 2>&1
out="$(run "$S" export gemini 2>&1)"
check "export suggests the Gemini VS Code companion" grep -q 'google.gemini-cli-vscode-ide-companion' <<<"$out"

echo "== deepseek profile (Claude Code on DeepSeek)"
fresh
out="$(run "$S" agents)"
check "agents lists deepseek with CT 1054" grep -q 'deepseek *CT 1054 *Claude Code on DeepSeek' <<<"$out"
out="$(run "$S" up deepseek 2>&1)"; rc=$?
check "up deepseek without secrets exits 0" [ $rc -eq 0 ]
[ $rc -eq 0 ] || echo "$out" | tail -8
check "  ...with the DeepSeek Platform hint" bash -c 'grep -q "platform.deepseek.com/api_keys" <<<"$1" && grep -q "DEEPSEEK_API_KEY=" <<<"$1"' _ "$out"
P="$T/ct/1054/root/provision-base.sh"
check_sh "  ...own CT and hostname, Claude Code native installer, verify" 'grep -q "^hostname: ai-sandbox-deepseek$" "$T/conf/1054.conf" && grep -q "curl -fsSL https://claude.ai/install.sh | bash" "$P" && [ "$(tail -n1 "$P")" = "claude --version" ]'
M="$T/ct/1054/etc/claude-code/managed-settings.json"
check_sh "  ...same managed-settings policy as claude (444)" '[ "$(stat -c %a "$M")" = 444 ] && python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[\"permissions\"][\"disableBypassPermissionsMode\"]==\"disable\" and d[\"allowedMcpServers\"]==[]" "$M"'
mkdir -p "$T/state/deepseek"; printf 'DEEPSEEK_API_KEY="sk-test_not.real"\n' > "$T/state/deepseek/secrets.env"; chmod 600 "$T/state/deepseek/secrets.env"
out="$(run FORCE=1 RESCUE=0 "$S" up deepseek 2>&1)"; rc=$?
U="$T/ct/1054/root/.claude/settings.json"
check_sh "key -> settings.json env: DeepSeek endpoint, auth token, default models (600)" '[ $rc -eq 0 ] && [ "$(stat -c %a "$U")" = 600 ] && python3 -c "
import json,sys; e=json.load(open(sys.argv[1]))[\"env\"]
assert e[\"ANTHROPIC_BASE_URL\"]==\"https://api.deepseek.com/anthropic\" and e[\"ANTHROPIC_AUTH_TOKEN\"]==\"sk-test_not.real\"
assert e[\"ANTHROPIC_MODEL\"]==e[\"ANTHROPIC_DEFAULT_OPUS_MODEL\"]==e[\"ANTHROPIC_DEFAULT_SONNET_MODEL\"]==\"deepseek-v4-pro\"
assert e[\"ANTHROPIC_DEFAULT_HAIKU_MODEL\"]==e[\"CLAUDE_CODE_SUBAGENT_MODEL\"]==\"deepseek-flash\"
assert \"ANTHROPIC_API_KEY\" not in e" "$U"'
printf 'DEEPSEEK_MODEL=deepseek-flash[1m]\nDEEPSEEK_SMALL_MODEL=deepseek-flash\n' > "$T/state/deepseek/config.env"; chmod 600 "$T/state/deepseek/config.env"
out="$(run FORCE=1 RESCUE=0 "$S" up deepseek 2>&1)"; rc=$?
check_sh "DEEPSEEK_MODEL in config.env overrides the main model ([1m] allowed)" '[ $rc -eq 0 ] && python3 -c "import json,sys; e=json.load(open(sys.argv[1]))[\"env\"]; assert e[\"ANTHROPIC_MODEL\"]==\"deepseek-flash[1m]\"" "$U"'
printf 'DEEPSEEK_MODEL=x","ANTHROPIC_BASE_URL":"http://evil\n' > "$T/state/deepseek/config.env"
out="$(run FORCE=1 RESCUE=0 "$S" up deepseek 2>&1)"; rc=$?
check_sh "a model name that could break the JSON is refused" '[ $rc -ne 0 ] && grep -q "invalid DeepSeek model name" <<<"$out"'
rm -f "$T/state/deepseek/config.env"
printf 'DEEPSEEK_API_KEY=sk-x$(touch %s/pwned)\n' "$T" > "$T/state/deepseek/secrets.env"
out="$(run FORCE=1 RESCUE=0 "$S" up deepseek 2>&1)"; rc=$?
check_sh "a key with shell metacharacters is refused, never executed" '[ $rc -ne 0 ] && grep -q "has characters a key never contains" <<<"$out" && [ ! -e "$T/pwned" ]'
printf 'ANTHROPIC_API_KEY=sk-ant-x\n' > "$T/state/deepseek/secrets.env"
out="$(run FORCE=1 RESCUE=0 "$S" up deepseek 2>&1)"; rc=$?
check_sh "a secrets file without DEEPSEEK_API_KEY fails clearly" '[ $rc -ne 0 ] && grep -q "no DEEPSEEK_API_KEY line" <<<"$out"'
out="$(run "$S" export deepseek 2>&1)"
check "export suggests the Claude Code VS Code extension" grep -q 'anthropic.claude-code' <<<"$out"


echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

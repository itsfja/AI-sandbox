#!/usr/bin/env bash
# shellcheck disable=SC2034  # out and rc are read inside check_sh's eval'd conditions
# Tests for ai-sandbox-remote.sh, the restricted SSH entry point. Runs as
# any user: ai-sandbox.sh is replaced by a stub that records its argv, and
# STATE_DIR / AUTHORIZED_KEYS point into a temp dir.
# Usage: bash tests/run-remote-tests.sh [path/to/ai-sandbox-remote.sh]
set -uo pipefail
SRC="$(readlink -f "${1:-$(dirname "$0")/../ai-sandbox-remote.sh}")"
pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }
check_sh() { local d="$1"; shift; if eval "$1"; then ok "$d"; else bad "$d"; fi; }

fresh() {
  T="$(mktemp -d)"
  mkdir -p "$T/state/ssh" "$T/home/.ssh"
  # stub ai-sandbox.sh: logs argv; `agents` lists the built-ins plus every
  # drop-in, and refuses (like the real one) a drop-in containing REFUSE
  cat > "$T/ai-sandbox.sh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/calls"
if [ "\${1:-}" = agents ]; then
  for f in "$T/state/profiles"/*.sh; do
    [ -e "\$f" ] || continue
    grep -q REFUSE "\$f" && { echo "error: refusing \$f" >&2; exit 1; }
  done
  printf '%-10s CT %-6s %s\n' mistral 1051 "Mistral Vibe CLI" claude 1052 "Claude Code" gemini 1053 "Gemini CLI"
  for f in "$T/state/profiles"/*.sh; do [ -e "\$f" ] && printf '%-10s CT %-6s %s\n' "\$(basename "\$f" .sh)" 1055 drop-in; done
fi
exit 0
EOF
  chmod +x "$T/ai-sandbox.sh"
  : > "$T/calls"
}
R() {   # remote call: R "<ssh command line>" [stdin]
  env -u SSH_ORIGINAL_COMMAND AI_SANDBOX_SCRIPT="$T/ai-sandbox.sh" STATE_DIR="$T/state" \
    AUTHORIZED_KEYS="$T/home/.ssh/authorized_keys" SSH_ORIGINAL_COMMAND="$1" SSH_CLIENT="203.0.113.9 5000 22" \
    bash "$SRC" --remote <<<"${2:-}"
}
L() {   # local call: L <args...> (stdin passes through)
  env -u SSH_ORIGINAL_COMMAND AI_SANDBOX_SCRIPT="$T/ai-sandbox.sh" STATE_DIR="$T/state" \
    AUTHORIZED_KEYS="$T/home/.ssh/authorized_keys" bash "$SRC" "$@"
}
mode_of() { stat -c %a "$1"; }

echo "== allowed verbs reach ai-sandbox.sh as plain argv"
fresh
out="$(R "up claude" 2>&1)"; rc=$?
check_sh "up claude -> ai-sandbox.sh up claude" '[ $rc -eq 0 ] && grep -qx "up claude" "$T/calls"'
R "down mistral" >/dev/null 2>&1; R "reset gemini" >/dev/null 2>&1; R "ip claude" >/dev/null 2>&1
check_sh "down / reset / ip pass through" 'grep -qx "down mistral" "$T/calls" && grep -qx "reset gemini" "$T/calls" && grep -qx "ip claude" "$T/calls"'
R "status" >/dev/null 2>&1; R "status claude" >/dev/null 2>&1
check_sh "status with and without an agent" 'grep -qx "status" "$T/calls" && grep -qx "status claude" "$T/calls"'
out="$(R "agents" 2>&1)"
check_sh "agents lists the profiles" 'grep -q "^claude " <<<"$out"'
out="$(R "" 2>&1)"; rc=$?
check_sh "no command prints the verb list" '[ $rc -eq 0 ] && grep -q "ai-sandbox-remote verbs" <<<"$out"'

echo "== everything else is refused"
fresh
for c in "purge claude" "shell claude" "ssh claude" "bake" "update" "export claude" "bash" "hook 1051 pre-start" "timer off"; do
  out="$(R "$c" 2>&1)"; rc=$?
  check_sh "refused: $c" '[ $rc -ne 0 ] && grep -q "not allowed" <<<"$out"'
done
check_sh "  ...and none reached ai-sandbox.sh" '[ ! -s "$T/calls" ] || ! grep -qvx "agents" "$T/calls"'
fresh
out="$(R "up claude; touch $T/pwned" 2>&1)"; rc=$?
check_sh "shell syntax is never evaluated (extra words refused)" '[ $rc -ne 0 ] && [ ! -e "$T/pwned" ] && ! grep -q "^up" "$T/calls"'
out="$(R 'up $(touch '"$T"'/pwned2)' 2>&1)"; rc=$?
check_sh "command substitution is just a bad agent name" '[ $rc -ne 0 ] && [ ! -e "$T/pwned2" ]'
out="$(R "up nosuchagent" 2>&1)"; rc=$?
check_sh "unknown agent refused" '[ $rc -ne 0 ] && grep -q "unknown agent" <<<"$out" && ! grep -q "^up" "$T/calls"'
out="$(R "up Claude" 2>&1)"; rc=$?
check_sh "invalid agent name refused" '[ $rc -ne 0 ] && ! grep -q "^up" "$T/calls"'
out="$(R "up" 2>&1)"; rc=$?
check_sh "missing agent refused" '[ $rc -ne 0 ] && grep -q "usage: up <agent>" <<<"$out"'
out="$(R "up claude extra" 2>&1)"; rc=$?
check_sh "extra argument refused" '[ $rc -ne 0 ] && ! grep -q "^up" "$T/calls"'

echo "== key"
fresh
out="$(R "key" 2>&1)"; rc=$?
check_sh "key before the first up fails clearly" '[ $rc -ne 0 ] && grep -q "no sandbox keypair yet" <<<"$out"'
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n' > "$T/state/ssh/ai-sandbox"
out="$(R "key" 2>&1)"; rc=$?
check_sh "key prints the sandbox private key" '[ $rc -eq 0 ] && grep -q "BEGIN OPENSSH PRIVATE KEY" <<<"$out"'

echo "== secret"
fresh
out="$(R "secret claude ANTHROPIC_API_KEY" "sk-ant-test_not.real" 2>&1)"; rc=$?
F="$T/state/claude/secrets.env"
check_sh "secret writes NAME=value" '[ $rc -eq 0 ] && grep -qx "ANTHROPIC_API_KEY=sk-ant-test_not.real" "$F"'
check_sh "  ...file mode 600, dir mode 700" '[ "$(mode_of "$F")" = 600 ] && [ "$(mode_of "$T/state/claude")" = 700 ]'
check_sh "  ...and the value is not echoed back" '! grep -q "sk-ant-test" <<<"$out"'
printf 'OTHER=keep\nANTHROPIC_API_KEY=old\n' > "$F"
R "secret claude ANTHROPIC_API_KEY" "sk-new" >/dev/null 2>&1
check_sh "secret replaces only its own line" 'grep -qx "OTHER=keep" "$F" && grep -qx "ANTHROPIC_API_KEY=sk-new" "$F" && [ "$(grep -c ANTHROPIC_API_KEY "$F")" = 1 ]'
R "secret claude ANTHROPIC_API_KEY" $'sk-crlf\r' >/dev/null 2>&1
check_sh "a trailing CR (PowerShell pipe) is stripped" 'grep -qx "ANTHROPIC_API_KEY=sk-crlf" "$F"'
R "secret claude ANTHROPIC_API_KEY" $'\xEF\xBB\xBFsk-bom\r' >/dev/null 2>&1
check_sh "a UTF-8 byte-order mark in front is stripped" 'grep -qx "ANTHROPIC_API_KEY=sk-bom" "$F"'
R "secret claude ANTHROPIC_API_KEY" "sk-crlf" >/dev/null 2>&1
out="$(R "secret claude ANTHROPIC_API_KEY" 'sk-x$(touch '"$T"'/pwned)' 2>&1)"; rc=$?
check_sh "a value with shell syntax is refused, file unchanged" '[ $rc -ne 0 ] && grep -qx "ANTHROPIC_API_KEY=sk-crlf" "$F" && [ ! -e "$T/pwned" ]'
out="$(R "secret claude ANTHROPIC_API_KEY" "" 2>&1)"; rc=$?
check_sh "an empty value is refused" '[ $rc -ne 0 ] && grep -qx "ANTHROPIC_API_KEY=sk-crlf" "$F"'
out="$(R "secret claude bad-name" "x" 2>&1)"; rc=$?
check_sh "an invalid NAME is refused" '[ $rc -ne 0 ] && grep -q "invalid secret name" <<<"$out"'
out="$(R "secret nosuch X_KEY" "x" 2>&1)"; rc=$?
check_sh "secret for an unknown agent is refused" '[ $rc -ne 0 ] && [ ! -e "$T/state/nosuch" ]'
out="$(R "secret ../etc X" "x" 2>&1)"; rc=$?
check_sh "path traversal in the agent name is refused" '[ $rc -ne 0 ] && [ ! -e "$T/etc" ]'

echo "== profile (opt-in)"
fresh
P="$(printf 'profile_deepseek_meta() { PROFILE_CTID=1055; }\n' | base64 -w0)"
out="$(R "profile deepseek" "$P" 2>&1)"; rc=$?
check_sh "off by default" '[ $rc -ne 0 ] && grep -q "profile upload is off" <<<"$out" && [ ! -e "$T/state/profiles/deepseek.sh" ]'
printf 'REMOTE_PROFILES=on\n' > "$T/state/config.env"; chmod 600 "$T/state/config.env"
out="$(R "profile deepseek" "$P" 2>&1)"; rc=$?
D="$T/state/profiles/deepseek.sh"
check_sh "REMOTE_PROFILES=on: installed, mode 644" '[ $rc -eq 0 ] && grep -q profile_deepseek_meta "$D" && [ "$(mode_of "$D")" = 644 ]'
check_sh "  ...and the new agent is reported" 'grep -q "^deepseek " <<<"$out"'
out="$(R "profile deepseek" $'\xEF\xBB\xBF'"$P"$'\r' 2>&1)"; rc=$?
check_sh "a byte-order mark and CR around the base64 are ignored" '[ $rc -eq 0 ] && head -c 3 "$D" | grep -q "^pro"'
cp "$D" "$T/before0"
chmod 666 "$T/state/config.env"
out="$(R "profile deepseek" "$P" 2>&1)"; rc=$?
check_sh "a group/world-writable config.env is refused, not trusted" '[ $rc -ne 0 ] && grep -q "group/other-writable" <<<"$out" && cmp -s "$D" "$T/before0"'
chmod 600 "$T/state/config.env"
cp "$D" "$T/before"
out="$(R "profile deepseek" "$(printf 'profile_deepseek_meta() { :; } # REFUSE\n' | base64 -w0)" 2>&1)"; rc=$?
check_sh "a profile ai-sandbox.sh refuses is rolled back to the previous one" '[ $rc -ne 0 ] && grep -q "refused the profile" <<<"$out" && cmp -s "$D" "$T/before"'
out="$(R "profile newone" "$(printf '# REFUSE\nx() { :; }\n' | base64 -w0)" 2>&1)"; rc=$?
check_sh "a refused new profile is removed" '[ $rc -ne 0 ] && [ ! -e "$T/state/profiles/newone.sh" ]'
out="$(R "profile bad" "$(printf 'f() {\n' | base64 -w0)" 2>&1)"; rc=$?
check_sh "a syntax error is refused before install" '[ $rc -ne 0 ] && grep -q "syntax error" <<<"$out" && [ ! -e "$T/state/profiles/bad.sh" ]'
out="$(R "profile claude" "$P" 2>&1)"; rc=$?
check_sh "a built-in agent cannot be replaced" '[ $rc -ne 0 ] && grep -q "built-in agent" <<<"$out"'
out="$(R "profile junk" "not base64 !!" 2>&1)"; rc=$?
check_sh "invalid base64 is refused" '[ $rc -ne 0 ] && [ ! -e "$T/state/profiles/junk.sh" ]'

echo "== local key management"
fresh
K="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnlyNotARealKey0000000000 me@desk"
out="$(L install-key <<<"$K" 2>&1)"; rc=$?
AK="$T/home/.ssh/authorized_keys"
check_sh "install-key writes a restricted, forced-command entry" '[ $rc -eq 0 ] && grep -q "^restrict,pty,command=\"[^\"]*ai-sandbox-remote.sh --remote\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFake[A-Za-z0-9]* ai-sandbox-remote$" "$AK"'
check_sh "  ...authorized_keys mode 600" '[ "$(mode_of "$AK")" = 600 ]'
L install-key <<<"$K" >/dev/null 2>&1
check_sh "install-key is idempotent" '[ "$(grep -c ai-sandbox-remote "$AK")" = 1 ]'
printf 'ssh-ed25519 AAAAFullRootKey0000 admin\n' >> "$AK"
out="$(L install-key <<<"ssh-ed25519 AAAAFullRootKey0000 x" 2>&1)"; rc=$?
check_sh "a key that already has full root access is refused" '[ $rc -ne 0 ] && grep -q "other access" <<<"$out" && grep -qx "ssh-ed25519 AAAAFullRootKey0000 admin" "$AK"'
out="$(L install-key <<<'command="evil" ssh-ed25519 AAAA x' 2>&1)"; rc=$?
check_sh "a line with options is refused" '[ $rc -ne 0 ] && ! grep -q evil "$AK"'
out="$(L list-keys 2>&1)"
check_sh "list-keys shows the restricted key only" 'grep -q ai-sandbox-remote <<<"$out" && ! grep -q FullRootKey <<<"$out"'
out="$(L remove-keys 2>&1)"
check_sh "remove-keys drops restricted keys, keeps others" '! grep -q ai-sandbox-remote "$AK" && grep -q FullRootKey "$AK"'
out="$(env AUTHORIZED_KEYS="$T/other_keys" SSH_ORIGINAL_COMMAND="x" bash "$SRC" install-key <<<"$K" 2>&1)"; rc=$?
check_sh "key management refuses to run over ssh" '[ $rc -ne 0 ] && grep -q "local only" <<<"$out" && [ ! -e "$T/other_keys" ]'
fresh
mkdir -p "$T/pvecfs"; printf 'ssh-rsa AAAAClusterNodeKey root@pve2\n' > "$T/pvecfs/authorized_keys"
ln -s "$T/pvecfs/authorized_keys" "$T/home/.ssh/authorized_keys"
L install-key <<<"$K" >/dev/null 2>&1; L remove-keys >/dev/null 2>&1; L install-key <<<"$K" >/dev/null 2>&1
check_sh "a symlinked authorized_keys (PVE cluster fs) stays a symlink, written through" '[ -L "$T/home/.ssh/authorized_keys" ] && grep -q ai-sandbox-remote "$T/pvecfs/authorized_keys" && grep -q ClusterNodeKey "$T/pvecfs/authorized_keys"'
out="$(L 2>&1)"; rc=$?
check_sh "no arguments prints usage" '[ $rc -ne 0 ] && grep -q "Remote verbs" <<<"$out"'

echo "== install-script (init: use the ai-sandbox.sh the host already runs)"
IS() {   # install-script in a fake /root ($T/root) with a fake snippets dir
  env -u SSH_ORIGINAL_COMMAND AI_SANDBOX_SCRIPT="$T/root/ai-sandbox.sh" HOOK_SNIPPET_DIR="$T/snip" \
    AUTHORIZED_KEYS="$T/home/.ssh/authorized_keys" bash "$SRC" install-script "$@"
}
fresh_root() {
  fresh; mkdir -p "$T/root" "$T/snip"
  printf '#!/usr/bin/env bash\necho fresh-copy\n' > "$T/copy.sh"
}
make_clone() {   # $1 = dir under $T/root
  mkdir -p "$T/root/$1/.git"; printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$T/root/$1/ai-sandbox.sh"
}
fresh_root
out="$(IS "$T/copy.sh" "" 2>&1)"; rc=$?
check_sh "nothing on the host: installs the copy" '[ $rc -eq 0 ] && [ -f "$T/root/ai-sandbox.sh" ] && [ ! -L "$T/root/ai-sandbox.sh" ] && grep -q fresh-copy "$T/root/ai-sandbox.sh" && grep -q "self-updates" <<<"$out"'
fresh_root; make_clone AI-sandbox
out="$(IS "$T/copy.sh" "" 2>&1)"; rc=$?
check_sh "a git clone beside it: links to the clone, no copy" '[ $rc -eq 0 ] && [ -L "$T/root/ai-sandbox.sh" ] && [ "$(readlink -f "$T/root/ai-sandbox.sh")" = "$(readlink -f "$T/root/AI-sandbox/ai-sandbox.sh")" ]'
fresh_root; make_clone AI-sandbox; make_clone other
mkdir -p "$T/elsewhere"; printf '#!/usr/bin/env bash\n' > "$T/elsewhere/ai-sandbox.sh"
printf '#!/usr/bin/env bash\nvmid="$1"; phase="$2"\nexec %s hook "$vmid" "$phase"\n' "$T/elsewhere/ai-sandbox.sh" > "$T/snip/ai-sandbox-hook.sh"
out="$(IS "$T/copy.sh" "" 2>&1)"; rc=$?
check_sh "the script the GUI hook shim runs wins over clones" '[ $rc -eq 0 ] && [ "$(readlink -f "$T/root/ai-sandbox.sh")" = "$(readlink -f "$T/elsewhere/ai-sandbox.sh")" ]'
fresh_root; make_clone AI-sandbox; make_clone other
out="$(IS "$T/copy.sh" "" 2>&1)"; rc=$?
check_sh "two clones and no hook: does not guess, installs the copy" '[ $rc -eq 0 ] && [ ! -L "$T/root/ai-sandbox.sh" ] && grep -q "not guessing" <<<"$out"'
fresh_root; make_clone AI-sandbox; cp "$T/copy.sh" "$T/root/ai-sandbox.sh"
printf '#!/usr/bin/env bash\nexec %s hook "$1" "$2"\n' "$T/root/AI-sandbox/ai-sandbox.sh" > "$T/snip/ai-sandbox-hook.sh"
out="$(IS "$T/copy.sh" "" 2>&1)"; rc=$?
check_sh "an existing copy is kept, with a warning when the GUI hooks run another" '[ $rc -eq 0 ] && [ ! -L "$T/root/ai-sandbox.sh" ] && grep -q "keeping the existing" <<<"$out" && grep -q "GUI hooks run" <<<"$out"'
out="$(IS "$T/copy.sh" "$T/root/AI-sandbox/ai-sandbox.sh" 2>&1)"; rc=$?
check_sh "-PveScript links to that path and keeps the old copy as .bak" '[ $rc -eq 0 ] && [ -L "$T/root/ai-sandbox.sh" ] && [ -f "$T/root/ai-sandbox.sh.bak" ] && grep -q fresh-copy "$T/root/ai-sandbox.sh.bak"'
out="$(IS "$T/copy.sh" "$T/root/AI-sandbox/ai-sandbox.sh" 2>&1)"; rc=$?
check_sh "  ...and is idempotent" '[ $rc -eq 0 ] && grep -q "already" <<<"$out"'
out="$(IS "$T/copy.sh" "$T/root/nope/ai-sandbox.sh" 2>&1)"; rc=$?
check_sh "-PveScript to a missing file is refused" '[ $rc -ne 0 ] && grep -q "no ai-sandbox.sh at" <<<"$out"'
out="$(IS "$T/copy.sh" '/root/x;rm -rf /' 2>&1)"; rc=$?
check_sh "-PveScript with shell characters is refused" '[ $rc -ne 0 ] && grep -q "invalid path" <<<"$out"'

echo "== review fixes: failures never shrink a file"
# a grep that fails mid-filter (as on a full /tmp): writes part, exits 2
mkdir -p "$T/badbin"
fake_grep() {
  rm -rf "$T/badbin"; mkdir -p "$T/badbin"
  cat > "$T/badbin/grep" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in -v|-vE|-vF) echo "partial"; exit 2 ;; esac; done
exec /usr/bin/env -S PATH=/usr/bin:/bin grep "$@"
EOF
  chmod +x "$T/badbin/grep"
}
fresh; fake_grep
printf 'ssh-ed25519 AAAAAdminKey admin@desk\nssh-rsa AAAANodeKey root@pve2\n' > "$T/home/.ssh/authorized_keys"
cp "$T/home/.ssh/authorized_keys" "$T/ak.before"
out="$(PATH="$T/badbin:$PATH" L install-key <<<"$K" 2>&1)"; rc=$?
check_sh "install-key: a failing grep leaves authorized_keys untouched" '[ $rc -ne 0 ] && cmp -s "$T/home/.ssh/authorized_keys" "$T/ak.before"'
L install-key <<<"$K" >/dev/null 2>&1; cp "$T/home/.ssh/authorized_keys" "$T/ak.before"
out="$(PATH="$T/badbin:$PATH" L remove-keys 2>&1)"; rc=$?
check_sh "remove-keys: a failing grep leaves authorized_keys untouched" '[ $rc -ne 0 ] && cmp -s "$T/home/.ssh/authorized_keys" "$T/ak.before" && grep -q AdminKey "$T/home/.ssh/authorized_keys"'
printf 'OTHER=keep\nANTHROPIC_API_KEY=old\n' > "$T/state/claude.tmp"; mkdir -p "$T/state/claude"; mv "$T/state/claude.tmp" "$T/state/claude/secrets.env"
cp "$T/state/claude/secrets.env" "$T/sec.before"
out="$(PATH="$T/badbin:$PATH" R "secret claude ANTHROPIC_API_KEY" "sk-new-value" 2>&1)"; rc=$?
check_sh "secret: a failing grep leaves secrets.env untouched" '[ $rc -ne 0 ] && cmp -s "$T/state/claude/secrets.env" "$T/sec.before" && grep -q "nothing changed" <<<"$out"'

echo "== review fixes: restricted entries are matched by their forced command"
fresh
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnlyNotARealKey0000000000 ai-sandbox-remote\n' > "$T/home/.ssh/authorized_keys"
out="$(L install-key <<<"$K" 2>&1)"; rc=$?
check_sh "a full-root line with the tag as its comment is refused, not restricted" '[ $rc -ne 0 ] && grep -q "other access" <<<"$out" && ! grep -q "^restrict," "$T/home/.ssh/authorized_keys"'
printf 'ssh-ed25519 AAAAOtherFullRoot ai-sandbox-remote\n' > "$T/home/.ssh/authorized_keys"
L install-key <<<"$K" >/dev/null 2>&1
out="$(L list-keys 2>&1)"
check_sh "list-keys ignores a full-root line with the tag comment" 'grep -q "^restrict," <<<"$out" && ! grep -q OtherFullRoot <<<"$out"'
L remove-keys >/dev/null 2>&1
check_sh "remove-keys keeps a full-root line with the tag comment" 'grep -q OtherFullRoot "$T/home/.ssh/authorized_keys" && ! grep -q "^restrict," "$T/home/.ssh/authorized_keys"'
printf 'ssh-ed25519 AAAAOnlyLine x' > "$T/home/.ssh/authorized_keys"   # no trailing newline
L install-key <<<"$K" >/dev/null 2>&1; rc=$?
check_sh "a last line without a newline is kept" '[ $rc -eq 0 ] && grep -q AAAAOnlyLine "$T/home/.ssh/authorized_keys" && grep -q "^restrict," "$T/home/.ssh/authorized_keys"'

echo "== review fixes: config overrides ai-sandbox.sh honours"
fresh
mkdir -p "$T/custom" "$T/state/claude"
printf 'SECRETS_FILE=%s/custom/claude.env\n' "$T" > "$T/state/claude/config.env"; chmod 600 "$T/state/claude/config.env"
out="$(R "secret claude ANTHROPIC_API_KEY" "sk-custom-path" 2>&1)"; rc=$?
check_sh "secret writes to SECRETS_FILE from <agent>/config.env" '[ $rc -eq 0 ] && grep -qx "ANTHROPIC_API_KEY=sk-custom-path" "$T/custom/claude.env" && [ ! -e "$T/state/claude/secrets.env" ]'
printf 'SECRETS_FILE=relative/x.env\n' > "$T/state/claude/config.env"
out="$(R "secret claude ANTHROPIC_API_KEY" "sk-x-value" 2>&1)"; rc=$?
check_sh "a SECRETS_FILE that is not a plain absolute path is refused" '[ $rc -ne 0 ] && grep -q "not a plain absolute path" <<<"$out"'
rm -f "$T/state/claude/config.env"
printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\ncustom\n-----END OPENSSH PRIVATE KEY-----\n' > "$T/custom/key"
printf 'SSH_KEY_FILE=%s/custom/key\n' "$T" > "$T/state/config.env"; chmod 600 "$T/state/config.env"
out="$(R "key claude" 2>&1)"; rc=$?
check_sh "key returns SSH_KEY_FILE from config.env" '[ $rc -eq 0 ] && grep -q custom <<<"$out"'
printf 'SSH_PUBKEY=/root/.ssh/id_ed25519.pub\n' > "$T/state/config.env"
out="$(R "key claude" 2>&1)"; rc=$?
check_sh "key refuses under SSH_PUBKEY (no managed key to hand out)" '[ $rc -ne 0 ] && grep -q "sets SSH_PUBKEY" <<<"$out"'
out="$(R "key nosuch" 2>&1)"; rc=$?
check_sh "key for an unknown agent is refused" '[ $rc -ne 0 ] && grep -q "unknown agent" <<<"$out"'
rm -f "$T/state/config.env"

echo "== review fixes: claude's two credential names"
fresh
mkdir -p "$T/state/claude"; printf 'ANTHROPIC_API_KEY=sk-ant-api-old\nOTHER=keep\n' > "$T/state/claude/secrets.env"
R "secret claude CLAUDE_CODE_OAUTH_TOKEN" "sk-ant-oat01-new" >/dev/null 2>&1
F="$T/state/claude/secrets.env"
check_sh "setting the token drops the API key (claude reads one or the other)" 'grep -qx "CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-new" "$F" && ! grep -q ANTHROPIC_API_KEY "$F" && grep -qx OTHER=keep "$F"'
R "secret claude ANTHROPIC_API_KEY" "sk-ant-api-new" >/dev/null 2>&1
check_sh "  ...and setting the API key drops the token" 'grep -qx "ANTHROPIC_API_KEY=sk-ant-api-new" "$F" && ! grep -q CLAUDE_CODE_OAUTH_TOKEN "$F"'
mkdir -p "$T/state/gemini"; printf 'GEMINI_API_KEY=a\nOTHER_KEY=b\n' > "$T/state/gemini/secrets.env"
R "secret gemini GEMINI_API_KEY" "new-gemini-key" >/dev/null 2>&1
check_sh "other agents keep their other lines" 'grep -qx OTHER_KEY=b "$T/state/gemini/secrets.env"'

echo "== review fixes: relinking never drops a provision.sh"
fresh_root; make_clone AI-sandbox
cp "$T/copy.sh" "$T/root/ai-sandbox.sh"; printf 'echo my-hook\n' > "$T/root/provision.sh"
out="$(IS "$T/copy.sh" "$T/root/AI-sandbox/ai-sandbox.sh" 2>&1)"; rc=$?
check_sh "-PveScript refuses while a provision.sh beside the old copy would stop running" '[ $rc -ne 0 ] && grep -q "refusing to relink" <<<"$out" && [ ! -L "$T/root/ai-sandbox.sh" ] && [ ! -e "$T/root/ai-sandbox.sh.bak" ]'
cp "$T/root/provision.sh" "$T/root/AI-sandbox/provision.sh"
out="$(IS "$T/copy.sh" "$T/root/AI-sandbox/ai-sandbox.sh" 2>&1)"; rc=$?
check_sh "  ...and links once the same provision.sh is beside the clone" '[ $rc -eq 0 ] && grep -q "^linked" <<<"$out"'

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]

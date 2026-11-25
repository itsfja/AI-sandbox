# shellcheck shell=bash disable=SC2034  # sourced by ai-sandbox.sh; it reads the PROFILE_* vars
# Drop-in agent profile: OpenAI Codex CLI (agent "codex", CT 1054).
#
# Install it on the Proxmox host with:
#   install -D -o root -g root -m 644 examples/profiles/codex.sh /root/.ai-sandbox/profiles/codex.sh
# then:
#   install -d -m 700 /root/.ai-sandbox/codex
#   printf 'OPENAI_API_KEY=<key>\n' > /root/.ai-sandbox/codex/secrets.env
#   chmod 600 /root/.ai-sandbox/codex/secrets.env
#   /root/ai-sandbox.sh up codex
#
# A drop-in is sourced as root on every run, so ai-sandbox.sh refuses it
# unless it is root-owned and not group/other-writable, and it may only
# define profile_<agent>_* functions (see README, "Writing a profile").
# Checked against the Codex docs (install, auth, managed configuration);
# treat it as an example to adapt, and test it on your host.

profile_codex_meta() {
  PROFILE_CTID=1054
  PROFILE_LABEL="OpenAI Codex CLI"
  PROFILE_VSCODE_EXT="openai.chatgpt"
}

# Codex ships as an npm package; Node 20+ comes from NodeSource when the CT
# has none (Debian 12 ships 18). In a golden template that also bakes the
# Gemini profile, Node is already there and this step is skipped.
profile_codex_install() {
  cat <<'EOF'
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y -qq --no-install-recommends -o Dpkg::Use-Pty=0 nodejs
fi
npm install -g --no-fund --no-audit @openai/codex
EOF
}

profile_codex_verify() { echo "codex --version"; }

# secrets.env: OPENAI_API_KEY=<key>, parsed (never executed) with the
# script's secrets_get. The key reaches `codex login --with-api-key` on
# stdin, never on a command line, and Codex caches it in ~/.codex/auth.json.
profile_codex_credentials() {
  local key
  key="$(secrets_get OPENAI_API_KEY "$SECRETS_FILE")"
  [ -n "$key" ] || die "no OPENAI_API_KEY line in $SECRETS_FILE"
  [[ "$key" =~ ^[A-Za-z0-9_-]+$ ]] || die "OPENAI_API_KEY in $SECRETS_FILE has characters a key never contains"
  printf '%s\n' "$key" | ct_run codex login --with-api-key >/dev/null \
    || die "codex login --with-api-key failed in CT $CTID"
  echo "credentials injected (host: $SECRETS_FILE -> CT: /root/.codex/auth.json via codex login)"
}

profile_codex_credential_paths() { echo /root/.codex/auth.json; }

profile_codex_credentials_hint() {
  echo "  create an API key at platform.openai.com (API keys), then run:"
  echo "    printf 'OPENAI_API_KEY=<key>\\n' > $SECRETS_FILE && chmod 600 $SECRETS_FILE"
}

# /etc/codex/requirements.toml: admin-enforced requirements users cannot
# override.
#   AGENT_AUTO_APPROVE  no `--ask-for-approval never`, no danger-full-access
#                       sandbox (which also rules out --yolo)
#   AGENT_MCP           an mcp_servers table that is present but empty
#                       disables every MCP server
#   AGENT_CONNECTORS    Codex has no equivalent in requirements.toml; no-op
profile_codex_policy() {
  local tmp
  tmp="$(mktemp)"
  {
    echo "# ai-sandbox: managed by ai-sandbox.sh (codex drop-in profile)"
    if [ "$AGENT_AUTO_APPROVE" != on ]; then
      echo 'allowed_approval_policies = ["untrusted", "on-request"]'
      echo 'allowed_sandbox_modes = ["read-only", "workspace-write"]'
    fi
    if [ "$AGENT_MCP" != on ]; then
      echo
      echo "[mcp_servers]"
    fi
  } > "$tmp"
  ct_push_file "$tmp" /etc/codex/requirements.toml 444 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  echo "hardening: injected /etc/codex/requirements.toml"
}

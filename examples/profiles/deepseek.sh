# shellcheck shell=bash disable=SC2034  # sourced by ai-sandbox.sh; it reads the PROFILE_* vars
# Drop-in agent profile: Claude Code on DeepSeek (agent "deepseek", CT 1055).
#
# The same Claude Code CLI, policy and VS Code extension as the built-in
# `claude` profile, in its own CT, pointed at DeepSeek's Anthropic-compatible
# API (https://api.deepseek.com/anthropic) with a DeepSeek Platform key.
# No Anthropic account or key is involved. It runs alongside `claude`, so
# you can compare the two.
#
# Install it on the Proxmox host with:
#   install -D -o root -g root -m 644 examples/profiles/deepseek.sh /root/.ai-sandbox/profiles/deepseek.sh
# then (key from platform.deepseek.com/api_keys, pay-as-you-go):
#   install -d -m 700 /root/.ai-sandbox/deepseek
#   printf 'DEEPSEEK_API_KEY=<key>\n' > /root/.ai-sandbox/deepseek/secrets.env
#   chmod 600 /root/.ai-sandbox/deepseek/secrets.env
#   /root/ai-sandbox.sh up deepseek
#
# Models: DeepSeek accepts deepseek-v4-pro and deepseek-flash (and maps
# claude-opus* to the first, other claude* names to the second). By default
# the main model and Claude Code's Opus and Sonnet slots use deepseek-v4-pro,
# the Haiku slot and subagents deepseek-flash. Override them in
# /root/.ai-sandbox/deepseek/config.env:
#   DEEPSEEK_MODEL=deepseek-flash[1m]     # [1m] = Claude Code's 1M-context mode
#   DEEPSEEK_SMALL_MODEL=deepseek-flash
# `/model` inside a session still switches between the slots.
#
# Limits are DeepSeek's, not the sandbox's: prompt caching is ignored (long
# sessions cost more than the token count suggests), MCP fields are ignored
# (MCP is off here anyway), image support depends on the model, and web
# search runs through DeepSeek's own tool, billed as extra tokens.
#
# Settings follow DeepSeek's docs ("Integrate with Claude Code", "Using the
# Anthropic API"); treat this as an example to adapt, and test it on your host.

profile_deepseek_meta() {
  PROFILE_CTID=1055
  PROFILE_LABEL="Claude Code on DeepSeek"
  PROFILE_VSCODE_EXT="anthropic.claude-code"
}

# Install, verify, policy and the credential path are the built-in claude
# profile's: the native installer, `claude --version`, the managed-settings
# default-deny, and /root/.claude/settings.json. A bake that includes both
# installs Claude Code once.
profile_deepseek_install()          { profile_claude_install; }
profile_deepseek_verify()           { profile_claude_verify; }
profile_deepseek_policy()           { profile_claude_policy; }
profile_deepseek_credential_paths() { profile_claude_credential_paths; }

# secrets.env holds DEEPSEEK_API_KEY=sk-... Parsed, never executed; written
# with the endpoint and model names as the `env` block of the user settings,
# as the claude profile does with an Anthropic key.
profile_deepseek_credentials() {
  local base="https://api.deepseek.com/anthropic" key model small tmp v
  key="$(secrets_get DEEPSEEK_API_KEY "$SECRETS_FILE")"
  [ -n "$key" ] || die "no DEEPSEEK_API_KEY line in $SECRETS_FILE"
  [[ "$key" =~ ^[A-Za-z0-9_.-]+$ ]] || die "DEEPSEEK_API_KEY in $SECRETS_FILE has characters a key never contains"
  model="${DEEPSEEK_MODEL:-deepseek-v4-pro}"
  small="${DEEPSEEK_SMALL_MODEL:-deepseek-flash}"
  for v in "$model" "$small"; do
    # names only, so a config value can never break out of the JSON string
    [[ "$v" =~ ^[A-Za-z0-9_.:/-]+(\[1m\])?$ ]] || die "invalid DeepSeek model name '$v'"
  done
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "$base",
    "ANTHROPIC_AUTH_TOKEN": "$key",
    "ANTHROPIC_MODEL": "$model",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "$model",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "$model",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "$small",
    "CLAUDE_CODE_SUBAGENT_MODEL": "$small"
  }
}
EOF
  ct_push_file "$tmp" /root/.claude/settings.json 600 || { rm -f "$tmp"; return 1; }
  rm -f "$tmp"
  echo "credentials injected (host: $SECRETS_FILE -> CT: /root/.claude/settings.json env; $model / $small via $base)"
}

profile_deepseek_credentials_hint() {
  echo "  create a key at platform.deepseek.com/api_keys, then run:"
  echo "    printf 'DEEPSEEK_API_KEY=<key>\\n' > $SECRETS_FILE && chmod 600 $SECRETS_FILE"
}

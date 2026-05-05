#!/usr/bin/env bash
set -euo pipefail

export PATH="/root/.local/bin:${PATH}"
export HOME="${HOME:-/state}"

mkdir -p "$HOME/.takopi" "$HOME/.claude" /vault

# Compute defaults outside the heredoc. Bash parameter expansion strips
# embedded double-quotes from inline `${VAR:-default}` defaults during
# heredoc expansion, so we can't put a JSON array literal directly in the
# heredoc as a default. Pre-resolve the values into simple shell vars.
ALLOWED_TOOLS_DEFAULT='["Bash","Read","Edit","Write","Glob","Grep","LS","WebFetch"]'
DENIED_COMMANDS_DEFAULT='["Bash(rm *)","Bash(rmdir *)","Bash(chmod *)","Bash(chown *)","Bash(dd *)","Bash(mkfs *)","Bash(shred *)","Bash(sudo *)"]'

ENGINE="${TAKOPI_DEFAULT_ENGINE:-claude}"
PROJECT="${TAKOPI_DEFAULT_PROJECT:-obsidian}"
SHOW_RESUME_LINE="${TAKOPI_SHOW_RESUME_LINE:-true}"
SESSION_MODE="${TAKOPI_SESSION_MODE:-chat}"
MESSAGE_OVERFLOW="${TAKOPI_MESSAGE_OVERFLOW:-split}"
VOICE_ENABLED="${VOICE_TRANSCRIPTION_ENABLED:-false}"
VOICE_MODEL="${VOICE_TRANSCRIPTION_MODEL:-gpt-4o-mini-transcribe}"
TOPICS_ENABLED="${TAKOPI_TOPICS_ENABLED:-false}"
TOPICS_SCOPE="${TAKOPI_TOPICS_SCOPE:-auto}"
CLAUDE_MODEL_VAL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-$ALLOWED_TOOLS_DEFAULT}"
DENIED_COMMANDS="${CLAUDE_DENIED_COMMANDS:-$DENIED_COMMANDS_DEFAULT}"
USE_API_BILLING="${CLAUDE_USE_API_BILLING:-true}"

# Claude Code reads ~/.claude/settings.json on every invocation. Its
# `permissions.deny` rules are the actual security boundary: enforced
# regardless of permission mode or --dangerously-skip-permissions, and
# resilient to evasion via `bash -c`, `find -delete`, etc. Generate it
# from CLAUDE_DENIED_COMMANDS on every container boot so the deny list
# stays in sync with the env config.
render_claude_settings() {
  cat > "$HOME/.claude/settings.json" <<JSON
{
  "permissions": {
    "deny": ${DENIED_COMMANDS}
  }
}
JSON
}

render_takopi_config() {
  : "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
  : "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"

  {
    cat <<TOML
transport = "telegram"
default_engine = "${ENGINE}"
default_project = "${PROJECT}"

[transports.telegram]
bot_token = "${TELEGRAM_BOT_TOKEN}"
chat_id = ${TELEGRAM_CHAT_ID}
show_resume_line = ${SHOW_RESUME_LINE}
session_mode = "${SESSION_MODE}"
message_overflow = "${MESSAGE_OVERFLOW}"
voice_transcription = ${VOICE_ENABLED}
voice_transcription_model = "${VOICE_MODEL}"
TOML

    if [[ -n "${VOICE_TRANSCRIPTION_BASE_URL:-}" ]]; then
      echo "voice_transcription_base_url = \"${VOICE_TRANSCRIPTION_BASE_URL}\""
    fi

    if [[ -n "${VOICE_TRANSCRIPTION_API_KEY:-}" ]]; then
      echo "voice_transcription_api_key = \"${VOICE_TRANSCRIPTION_API_KEY}\""
    fi

    cat <<TOML

[transports.telegram.topics]
enabled = ${TOPICS_ENABLED}
scope = "${TOPICS_SCOPE}"

[projects.${PROJECT}]
path = "/vault"
default_engine = "${ENGINE}"

[claude]
model = "${CLAUDE_MODEL_VAL}"
allowed_tools = ${ALLOWED_TOOLS}
use_api_billing = ${USE_API_BILLING}
TOML
  } > "$HOME/.takopi/takopi.toml"
}

render_claude_settings
render_takopi_config

echo "Generated Claude settings at $HOME/.claude/settings.json"
echo "Generated Takopi config  at $HOME/.takopi/takopi.toml"

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

exec /root/.local/bin/takopi

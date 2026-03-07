#!/usr/bin/env bash
set -euo pipefail

export PATH="/root/.local/bin:${PATH}"
export HOME="${HOME:-/state}"

mkdir -p "$HOME/.takopi" "$HOME/.claude" /vault

render_config() {
  : "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
  : "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"

  cat > "$HOME/.takopi/takopi.toml" <<TOML
watch_config = true
transport = "telegram"
default_engine = "${TAKOPI_DEFAULT_ENGINE:-claude}"
default_project = "${TAKOPI_DEFAULT_PROJECT:-obsidian}"

[transports.telegram]
bot_token = "${TELEGRAM_BOT_TOKEN}"
chat_id = ${TELEGRAM_CHAT_ID}
show_resume_line = ${TAKOPI_SHOW_RESUME_LINE:-true}
session_mode = "${TAKOPI_SESSION_MODE:-chat}"
message_overflow = "${TAKOPI_MESSAGE_OVERFLOW:-split}"
voice_transcription = ${VOICE_TRANSCRIPTION_ENABLED:-false}
voice_transcription_model = "${VOICE_TRANSCRIPTION_MODEL:-gpt-4o-mini-transcribe}"
TOML

  if [[ -n "${VOICE_TRANSCRIPTION_BASE_URL:-}" ]]; then
    cat >> "$HOME/.takopi/takopi.toml" <<TOML
voice_transcription_base_url = "${VOICE_TRANSCRIPTION_BASE_URL}"
TOML
  fi

  if [[ -n "${VOICE_TRANSCRIPTION_API_KEY:-}" ]]; then
    cat >> "$HOME/.takopi/takopi.toml" <<TOML
voice_transcription_api_key = "${VOICE_TRANSCRIPTION_API_KEY}"
TOML
  fi

  cat >> "$HOME/.takopi/takopi.toml" <<TOML

[transports.telegram.topics]
enabled = ${TAKOPI_TOPICS_ENABLED:-false}
scope = "${TAKOPI_TOPICS_SCOPE:-auto}"

[projects.${TAKOPI_DEFAULT_PROJECT:-obsidian}]
path = "/vault"
default_engine = "${TAKOPI_DEFAULT_ENGINE:-claude}"

[claude]
model = "${CLAUDE_MODEL:-claude-sonnet-4-6}"
allowed_tools = ${CLAUDE_ALLOWED_TOOLS:-["Bash","Read","Edit","Write"]}
dangerously_skip_permissions = ${CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS:-false}
use_api_billing = ${CLAUDE_USE_API_BILLING:-false}
TOML
}

render_config

echo "Generated Takopi config at $HOME/.takopi/takopi.toml"

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

exec /root/.local/bin/takopi

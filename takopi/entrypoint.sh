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
DENIED_COMMANDS_DEFAULT='["Bash(rm *)","Bash(rmdir *)","Bash(chmod *)","Bash(chown *)","Bash(dd *)","Bash(mkfs *)","Bash(shred *)","Bash(sudo *)","Bash(find * -delete)","Bash(find * -exec rm *)","Bash(truncate *)"]'

ENGINE="${TAKOPI_DEFAULT_ENGINE:-claude}"
PROJECT="${TAKOPI_DEFAULT_PROJECT:-obsidian}"
SHOW_RESUME_LINE="${TAKOPI_SHOW_RESUME_LINE:-true}"
SESSION_MODE="${TAKOPI_SESSION_MODE:-chat}"
MESSAGE_OVERFLOW="${TAKOPI_MESSAGE_OVERFLOW:-split}"
VOICE_ENABLED="${VOICE_TRANSCRIPTION_ENABLED:-false}"
VOICE_MODEL="${VOICE_TRANSCRIPTION_MODEL:-gpt-4o-mini-transcribe}"
TOPICS_ENABLED="${TAKOPI_TOPICS_ENABLED:-false}"
TOPICS_SCOPE="${TAKOPI_TOPICS_SCOPE:-auto}"
CLAUDE_MODEL_VAL="${CLAUDE_MODEL:-claude-haiku-4-5}"
ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-$ALLOWED_TOOLS_DEFAULT}"
DENIED_COMMANDS="${CLAUDE_DENIED_COMMANDS:-$DENIED_COMMANDS_DEFAULT}"
USE_API_BILLING="${CLAUDE_USE_API_BILLING:-true}"

# Validate JSON-array env vars before they're interpolated into settings.json
# / takopi.toml. A malformed value here causes Claude Code to fail with a
# cryptic parse error and the container goes into restart-loop; failing fast
# here gives the operator a clear pointer at the broken variable.
validate_json_array() {
  local name="$1" value="$2"
  if ! python3 -c '
import json, sys
v = json.loads(sys.argv[1])
assert isinstance(v, list), "must be a JSON array"
' "$value" >/dev/null 2>&1; then
    echo "ERROR: $name is not a valid JSON array. Got: $value" >&2
    echo "  Expected format: [\"item1\",\"item2\",...]" >&2
    exit 1
  fi
}
validate_json_array CLAUDE_ALLOWED_TOOLS "$ALLOWED_TOOLS"
validate_json_array CLAUDE_DENIED_COMMANDS "$DENIED_COMMANDS"

# Claude Code reads ~/.claude/settings.json on every invocation. Its
# `permissions.deny` rules are enforced regardless of permission mode
# or --dangerously-skip-permissions. The patterns are literal-prefix
# matches against the Bash invocation, so the default list covers the
# obvious destructive primitives (rm, rmdir, chmod, find -delete,
# truncate, etc.) but cannot enumerate every shell evasion (e.g. a
# Python or Perl script that calls os.remove). Treat the deny list as
# a guard rail, not a sandbox — vault backups remain mandatory.
# Generate it from CLAUDE_DENIED_COMMANDS on every container boot so
# the deny list stays in sync with the env config.
render_claude_settings() {
  cat > "$HOME/.claude/settings.json" <<JSON
{
  "permissions": {
    "deny": ${DENIED_COMMANDS}
  }
}
JSON
}

# Auto-detect TELEGRAM_CHAT_ID from a one-time /claim message if it isn't set.
# Bound chat_id is persisted to $HOME/.takopi/chat_id, so this only runs once
# per install. The /claim flow (vs. "trust the first message") guards against
# bot-token leaks: an attacker would need both the bot token and the random
# claim token printed on the operator's container logs to bind the bot.
detect_chat_id() {
  if [[ -n "${TELEGRAM_CHAT_ID:-}" && "${TELEGRAM_CHAT_ID}" != "auto" ]]; then
    return 0
  fi

  local saved="$HOME/.takopi/chat_id"
  # -s (non-empty) catches the rare case where the container was killed
  # mid-write and left a 0-byte file from a previous /claim attempt.
  if [[ -s "$saved" ]]; then
    TELEGRAM_CHAT_ID="$(cat "$saved")"
    export TELEGRAM_CHAT_ID
    echo "Loaded persisted chat_id: ${TELEGRAM_CHAT_ID}"
    return 0
  fi
  if [[ -f "$saved" ]]; then
    echo "Warning: $saved exists but is empty — re-running /claim flow." >&2
    rm -f "$saved"
  fi

  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    echo "ERROR: TELEGRAM_BOT_TOKEN must be set for chat_id auto-detect." >&2
    exit 1
  fi

  local claim_token
  claim_token="$(head -c 16 /dev/urandom | base64 | tr -d '+/=' | head -c 12)"

  cat <<EOF

============================================================
  CHAT BINDING REQUIRED

  Open your Telegram chat with this bot and send:

      /claim ${claim_token}

  The bot will reply with confirmation and start serving
  only that chat. This binding survives container restarts.

  Waiting...
============================================================

EOF

  CLAIM_TOKEN="$claim_token" \
  CHAT_ID_FILE="$saved" \
    python3 - <<'PY'
import os
import sys
import time
import json
import urllib.request
import urllib.parse

token = os.environ["TELEGRAM_BOT_TOKEN"]
claim = os.environ["CLAIM_TOKEN"]
expected = f"/claim {claim}"
api = f"https://api.telegram.org/bot{token}"
offset = 0

while True:
    try:
        url = f"{api}/getUpdates?timeout=30&offset={offset}"
        with urllib.request.urlopen(url, timeout=35) as r:
            data = json.load(r)
        for upd in data.get("result", []):
            offset = upd["update_id"] + 1
            msg = upd.get("message") or upd.get("edited_message")
            if not msg:
                continue
            if msg.get("text", "").strip() == expected:
                chat_id = msg["chat"]["id"]
                with open(os.environ["CHAT_ID_FILE"], "w") as f:
                    f.write(str(chat_id))
                ack = f"{api}/sendMessage"
                payload = urllib.parse.urlencode({
                    "chat_id": chat_id,
                    "text": (
                        "Bound. From now on this bot only listens to chat "
                        f"{chat_id}."
                    ),
                }).encode()
                try:
                    urllib.request.urlopen(
                        urllib.request.Request(ack, data=payload),
                        timeout=10,
                    ).read()
                except Exception:
                    pass
                print(chat_id)
                sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as e:
        print(f"poll error: {e}", file=sys.stderr)
        time.sleep(2)
PY

  TELEGRAM_CHAT_ID="$(cat "$saved")"
  export TELEGRAM_CHAT_ID
  echo "Bound to chat_id: ${TELEGRAM_CHAT_ID}"
}

render_takopi_config() {
  : "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
  : "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required (auto-detect should have set it)}"

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

# Assemble /vault/CLAUDE.md from a stable base (tracked in repo) plus optional
# user/CI overlays (not tracked). Idempotent: re-runs every container start so
# the file always reflects the current sources.
#
#   CLAUDE.base.md           — repo-managed, updated via git pull
#   CLAUDE.local.md          — user-edited, persists in the vault volume
#   CLAUDE_EXTRA_INSTRUCTIONS — env var, useful for CI / GitHub Secrets
#
# Later sections override earlier ones, so personal rules in local/env beat
# the base when they conflict.
assemble_claude_md() {
  local out=/vault/CLAUDE.md
  local base=/vault/CLAUDE.base.md
  local local_file=/vault/CLAUDE.local.md

  if [[ ! -f "$base" ]]; then
    echo "Warning: $base missing — skipping CLAUDE.md assembly." >&2
    return 0
  fi

  {
    cat "$base"
    if [[ -s "$local_file" ]]; then
      printf '\n\n## User customizations (vault/CLAUDE.local.md)\n\n'
      cat "$local_file"
    fi
    if [[ -n "${CLAUDE_EXTRA_INSTRUCTIONS:-}" ]]; then
      printf '\n\n## Extra instructions (CLAUDE_EXTRA_INSTRUCTIONS)\n\n'
      printf '%s\n' "$CLAUDE_EXTRA_INSTRUCTIONS"
    fi
  } > "$out"
}

render_claude_settings
detect_chat_id
render_takopi_config
assemble_claude_md

echo "Generated Claude settings at $HOME/.claude/settings.json"
echo "Generated Takopi config  at $HOME/.takopi/takopi.toml"
echo "Assembled vault/CLAUDE.md from base + local + env"

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

exec /root/.local/bin/takopi

#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[info]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ok]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

NONINTERACTIVE="${NONINTERACTIVE:-0}"
[[ "$NONINTERACTIVE" == "true" ]] && NONINTERACTIVE=1

for arg in "$@"; do
  case "$arg" in
    --non-interactive|--noninteractive) NONINTERACTIVE=1 ;;
    -h|--help)
      cat <<EOF
Usage: install.sh [--non-interactive]

Configures and starts the Obsidian Telegram Agent stack.

Environment variables (override interactive prompts):
  TELEGRAM_BOT_TOKEN     Telegram bot token (required)
  ANTHROPIC_API_KEY      Anthropic API key (required)
  TELEGRAM_CHAT_ID       Telegram chat ID (optional — auto-detected via /claim)
  CLAUDE_MODEL           Claude model (default: claude-sonnet-4-6)
  TZ                     Timezone (default: Europe/Amsterdam)
  VOICE_TRANSCRIPTION_ENABLED  true/false (default: false)
  OPENAI_API_KEY         OpenAI key (only if voice enabled)
  IMAGE_TAG              GHCR image tag to pull (default: latest)

Non-interactive control:
  NONINTERACTIVE=1       Skip all prompts (also: --non-interactive)
  BACKUP_ACKNOWLEDGED=1  Required in non-interactive mode
  OVERWRITE_ENV=1        Recreate .env from env vars even if it exists
  SKIP_START=1           Configure but don't run "docker compose up"
EOF
      exit 0
      ;;
  esac
done

# Read input from /dev/tty so the script works under curl-pipe-bash too.
read_tty() {
  if [[ -e /dev/tty ]]; then
    read "$@" </dev/tty
  else
    read "$@"
  fi
}

# Ask for a value: prefer env var, then NONINTERACTIVE default, then prompt.
ask() {
  local var_name="$1" prompt="$2" default="${3:-}" reply

  if [[ -n "${!var_name:-}" ]]; then
    echo "${!var_name}"
    return 0
  fi

  if [[ "$NONINTERACTIVE" == "1" ]]; then
    if [[ -n "$default" ]]; then
      echo "$default"
      return 0
    fi
    error "Required setting '$var_name' is not set (NONINTERACTIVE mode requires env var)."
  fi

  if [[ -n "$default" ]]; then
    read_tty -rp "$(echo -e "${CYAN}$prompt${NC} [$default]: ")" reply
    echo "${reply:-$default}"
  else
    read_tty -rp "$(echo -e "${CYAN}$prompt${NC}: ")" reply
    echo "$reply"
  fi
}

# Like ask(), but empty input is a valid answer (no error in NONINTERACTIVE mode).
ask_optional() {
  local var_name="$1" prompt="$2" reply

  if [[ -n "${!var_name:-}" ]]; then
    echo "${!var_name}"
    return 0
  fi

  if [[ "$NONINTERACTIVE" == "1" ]]; then
    echo ""
    return 0
  fi

  read_tty -rp "$(echo -e "${CYAN}$prompt${NC}: ")" reply
  echo "$reply"
}

# Yes/no with env var override. Returns 0 (yes) or 1 (no).
ask_yn() {
  local var_name="$1" prompt="$2" default="${3:-N}" reply
  local val="${!var_name:-}"

  if [[ -n "$val" ]]; then
    case "${val,,}" in
      1|true|yes|y) return 0 ;;
      0|false|no|n) return 1 ;;
    esac
  fi

  if [[ "$NONINTERACTIVE" == "1" ]]; then
    [[ "$default" == "Y" ]] && return 0 || return 1
  fi

  read_tty -rp "$(echo -e "${CYAN}$prompt${NC} [$default]: ")" reply
  reply="${reply:-$default}"
  [[ "${reply,,}" == "y" ]] && return 0 || return 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo "============================================="
echo "  Obsidian Telegram Agent — Setup"
echo "============================================="
echo ""
[[ "$NONINTERACTIVE" == "1" ]] && info "Running in NONINTERACTIVE mode."
echo ""

# --- Backup warning ---
warn "This bot gives Claude shell-level read/write/delete access to your vault."
warn "An LLM can misinterpret instructions and damage or delete notes."
warn "Make sure you have an independent backup before pointing it at a vault you care about."
warn "See the 'Backups' section in the README for recommended approaches."
echo ""

if [[ "$NONINTERACTIVE" == "1" ]]; then
  if [[ "${BACKUP_ACKNOWLEDGED:-0}" != "1" ]]; then
    error "Set BACKUP_ACKNOWLEDGED=1 to confirm you have backups (NONINTERACTIVE mode)."
  fi
  ok "BACKUP_ACKNOWLEDGED=1 — proceeding."
else
  read_tty -rp "$(echo -e "${CYAN}Acknowledge and continue?${NC} [y/N]: ")" ack
  if [[ "${ack,,}" != "y" ]]; then
    info "Aborted. Set up backups first, then re-run."
    exit 0
  fi
fi
echo ""

# --- Check Docker ---
if ! command -v docker &>/dev/null; then
  warn "Docker is not installed."
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    info "NONINTERACTIVE mode — installing Docker via get.docker.com."
    DOCKER_INSTALL=yes
  elif ask_yn INSTALL_DOCKER "Install Docker now?" "Y"; then
    DOCKER_INSTALL=yes
  else
    DOCKER_INSTALL=no
  fi

  if [[ "$DOCKER_INSTALL" == "yes" ]]; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    ok "Docker installed."
  else
    error "Docker is required. Install it and re-run this script."
  fi
fi

if ! docker compose version &>/dev/null; then
  error "Docker Compose plugin is not available. Update Docker or install docker-compose-plugin."
fi

ok "Docker is ready."

# --- Configure .env ---
ENV_FILE="$PROJECT_DIR/.env"
SKIP_CONFIG=0

if [[ -f "$ENV_FILE" ]]; then
  if [[ "${OVERWRITE_ENV:-0}" == "1" ]]; then
    info "OVERWRITE_ENV=1 — recreating .env from env vars / prompts."
    : >"$ENV_FILE"
  elif [[ "$NONINTERACTIVE" == "1" ]]; then
    info "Existing .env found and OVERWRITE_ENV=0 — keeping it as-is."
    SKIP_CONFIG=1
  else
    warn "Existing .env found."
    if ask_yn OVERWRITE_ENV "Overwrite all values?" "N"; then
      : >"$ENV_FILE"
    else
      info "Keeping existing .env. Skipping configuration."
      SKIP_CONFIG=1
    fi
  fi
fi

if [[ "$SKIP_CONFIG" != "1" ]]; then
  echo ""
  echo "--- Required settings ---"
  echo ""

  TELEGRAM_BOT_TOKEN_VAL=$(ask TELEGRAM_BOT_TOKEN "Telegram bot token (from @BotFather)")
  [[ -z "$TELEGRAM_BOT_TOKEN_VAL" ]] && error "Telegram bot token is required."

  # chat_id is optional — if empty, the bot prints /claim <token> on first boot.
  TELEGRAM_CHAT_ID_VAL=$(ask_optional TELEGRAM_CHAT_ID \
    "Telegram chat ID (leave empty for auto-detect via /claim)")

  ANTHROPIC_API_KEY_VAL=$(ask ANTHROPIC_API_KEY "Anthropic API key (sk-ant-...)")
  [[ -z "$ANTHROPIC_API_KEY_VAL" ]] && error "Anthropic API key is required."

  echo ""
  echo "--- Optional settings (press Enter to accept defaults) ---"
  echo ""

  CLAUDE_MODEL_VAL=$(ask CLAUDE_MODEL "Claude model" "claude-sonnet-4-6")
  TZ_VAL=$(ask TZ "Timezone" "Europe/Amsterdam")

  VOICE_ENABLED_VAL="false"
  OPENAI_API_KEY_VAL="${OPENAI_API_KEY:-}"
  if ask_yn VOICE_TRANSCRIPTION_ENABLED "Enable voice note transcription?" "N"; then
    VOICE_ENABLED_VAL="true"
    OPENAI_API_KEY_VAL=$(ask OPENAI_API_KEY "OpenAI API key (for Whisper transcription)")
  fi

  cat >"$ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN_VAL
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID_VAL
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY_VAL
CLAUDE_MODEL=$CLAUDE_MODEL_VAL
CLAUDE_USE_API_BILLING=true
TZ=$TZ_VAL
TAKOPI_SESSION_MODE=chat
TAKOPI_MESSAGE_OVERFLOW=split
VOICE_TRANSCRIPTION_ENABLED=$VOICE_ENABLED_VAL
OPENAI_API_KEY=$OPENAI_API_KEY_VAL
OBSIDIAN_AUTOSTART_SYNC=false
EOF

  ok "Configuration saved to .env"
fi

# --- Start the stack ---
echo ""

START_NOW=0
if [[ "$NONINTERACTIVE" == "1" ]]; then
  if [[ "${SKIP_START:-0}" != "1" ]]; then
    START_NOW=1
  fi
elif ask_yn START_NOW "Start the stack now?" "Y"; then
  START_NOW=1
fi

if [[ "$START_NOW" == "1" ]]; then
  cd "$PROJECT_DIR"

  info "Pulling pre-built images from GHCR..."
  docker compose pull
  info "Starting containers..."
  docker compose up -d

  echo ""
  ok "Stack is running!"
  echo ""

  CHAT_ID_FROM_ENV=""
  if [[ -f "$ENV_FILE" ]]; then
    CHAT_ID_FROM_ENV=$(grep -E '^TELEGRAM_CHAT_ID=' "$ENV_FILE" | cut -d= -f2- || true)
  fi

  if [[ -z "$CHAT_ID_FROM_ENV" || "$CHAT_ID_FROM_ENV" == "auto" ]]; then
    info "TELEGRAM_CHAT_ID is unset — the bot will print a /claim <token> on first boot."
    info "  1. Tail the logs:  docker compose logs -f takopi"
    info "  2. Send the printed '/claim <token>' command to your bot in Telegram."
    info "  3. The bot will reply with confirmation and bind to that chat."
  else
    info "Send a message to your Telegram bot to test."
    info "Follow logs: docker compose logs -f takopi"
  fi
  echo ""
  info "To set up Obsidian Sync, run: ./scripts/auth-obsidian.sh login"
else
  echo ""
  info "To start later: cd $PROJECT_DIR && docker compose pull && docker compose up -d"
fi

echo ""
ok "Setup complete."

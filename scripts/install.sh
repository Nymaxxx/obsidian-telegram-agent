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
error() { echo -e "${RED}[error]${NC} $*"; exit 1; }

ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${CYAN}$prompt${NC} [$default]: ")" reply
    echo "${reply:-$default}"
  else
    read -rp "$(echo -e "${CYAN}$prompt${NC}: ")" reply
    echo "$reply"
  fi
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo ""
echo "============================================="
echo "  Obsidian Telegram Agent — Setup Wizard"
echo "============================================="
echo ""

warn "This bot gives Claude shell-level read/write/delete access to your vault."
warn "An LLM can misinterpret instructions and damage or delete notes."
warn "Make sure you have an independent backup before pointing it at a vault you care about."
warn "See the 'Backups' section in the README for recommended approaches."
echo ""
read -rp "$(echo -e "${CYAN}Acknowledge and continue?${NC} [y/N]: ")" ack
if [[ "${ack,,}" != "y" ]]; then
  info "Aborted. Set up backups first, then re-run."
  exit 0
fi
echo ""

# --- Check Docker ---
if ! command -v docker &>/dev/null; then
  warn "Docker is not installed."
  echo ""
  read -rp "Install Docker now? [Y/n]: " install_docker
  if [[ "${install_docker,,}" != "n" ]]; then
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

# --- Create .env ---
ENV_FILE="$PROJECT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  warn ".env already exists."
  read -rp "Overwrite it? [y/N]: " overwrite
  if [[ "${overwrite,,}" != "y" ]]; then
    info "Keeping existing .env. Skipping configuration."
    echo ""
    info "To start the stack: cd $PROJECT_DIR && docker compose up -d --build"
    exit 0
  fi
fi

echo ""
echo "--- Required settings ---"
echo ""

TELEGRAM_BOT_TOKEN=$(ask "Telegram bot token (from @BotFather)")
[[ -z "$TELEGRAM_BOT_TOKEN" ]] && error "Telegram bot token is required."

TELEGRAM_CHAT_ID=$(ask "Telegram chat ID")
[[ -z "$TELEGRAM_CHAT_ID" ]] && error "Telegram chat ID is required."

ANTHROPIC_API_KEY=$(ask "Anthropic API key (sk-ant-...)")
[[ -z "$ANTHROPIC_API_KEY" ]] && error "Anthropic API key is required."

echo ""
echo "--- Optional settings (press Enter to accept defaults) ---"
echo ""

CLAUDE_MODEL=$(ask "Claude model" "claude-sonnet-4-6")
TZ=$(ask "Timezone" "Europe/Amsterdam")

read -rp "$(echo -e "${CYAN}Enable voice note transcription?${NC} [y/N]: ")" enable_voice
VOICE_TRANSCRIPTION_ENABLED="false"
OPENAI_API_KEY=""
if [[ "${enable_voice,,}" == "y" ]]; then
  VOICE_TRANSCRIPTION_ENABLED="true"
  OPENAI_API_KEY=$(ask "OpenAI API key (for Whisper transcription)")
fi

cat > "$ENV_FILE" <<EOF
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_CHAT_ID=$TELEGRAM_CHAT_ID
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
CLAUDE_MODEL=$CLAUDE_MODEL
CLAUDE_USE_API_BILLING=true
TZ=$TZ
TAKOPI_SESSION_MODE=chat
TAKOPI_MESSAGE_OVERFLOW=split
VOICE_TRANSCRIPTION_ENABLED=$VOICE_TRANSCRIPTION_ENABLED
OPENAI_API_KEY=$OPENAI_API_KEY
OBSIDIAN_AUTOSTART_SYNC=false
EOF

ok "Configuration saved to .env"

# --- Start the stack ---
echo ""
read -rp "$(echo -e "${CYAN}Start the stack now?${NC} [Y/n]: ")" start_now
if [[ "${start_now,,}" != "n" ]]; then
  info "Building and starting containers..."
  cd "$PROJECT_DIR"
  docker compose up -d --build
  echo ""
  ok "Stack is running!"
  echo ""
  info "Send a message to your Telegram bot to test."
  info "Follow logs: docker compose logs -f takopi"
  echo ""
  info "To set up Obsidian Sync, run: ./scripts/auth-obsidian.sh login"
else
  echo ""
  info "To start later: cd $PROJECT_DIR && docker compose up -d --build"
fi

echo ""
ok "Setup complete."

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
  CLAUDE_MODEL           Claude model (default: claude-haiku-4-5)
  TZ                     Timezone (default: Europe/Amsterdam)
  VOICE_TRANSCRIPTION_ENABLED  true/false (default: false)
  OPENAI_API_KEY         OpenAI key (only if voice enabled)
  IMAGE_TAG              GHCR image tag to pull (default: latest)
  SETUP_OBSIDIAN_SYNC    true/false — run Obsidian Sync setup after start (default: false)
  OBSIDIAN_VAULT_NAME    Vault name for sync setup (required if SETUP_OBSIDIAN_SYNC=true)

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
# Strips carriage returns so Windows SSH clients (PuTTY, Windows Terminal, etc.)
# that send \r\n don't leave a stray \r in the variable and break comparisons.
read_tty() {
  if [[ -e /dev/tty ]]; then
    read "$@" </dev/tty
  else
    read "$@"
  fi
  # Strip carriage returns left by Windows SSH clients (\r\n → \n after read).
  # local -n creates a nameref that aliases the target variable directly,
  # so the assignment works regardless of whether the variable is global or
  # local in a calling function.
  local _varname="${!#}"
  if [[ -n "$_varname" && "$_varname" != -* ]]; then
    local -n _read_tty_ref="$_varname"
    _read_tty_ref="${_read_tty_ref//$'\r'/}"
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
  local var_name="$1" prompt="$2" default="${3:-N}" reply options
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

  [[ "$default" == "Y" ]] && options="Y/n" || options="y/N"
  read_tty -rp "$(echo -e "${CYAN}$prompt${NC} [$options]: ")" reply
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
  ack=""
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

  CLAUDE_MODEL_VAL=$(ask CLAUDE_MODEL "Claude model" "claude-haiku-4-5")
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
CLAUDE_USE_API_BILLING=${CLAUDE_USE_API_BILLING:-true}
TZ=$TZ_VAL
TAKOPI_SESSION_MODE=${TAKOPI_SESSION_MODE:-chat}
TAKOPI_MESSAGE_OVERFLOW=${TAKOPI_MESSAGE_OVERFLOW:-split}
VOICE_TRANSCRIPTION_ENABLED=$VOICE_ENABLED_VAL
OPENAI_API_KEY=$OPENAI_API_KEY_VAL
OBSIDIAN_AUTOSTART_SYNC=${OBSIDIAN_AUTOSTART_SYNC:-false}
EOF

  # Append optional env vars that were set by the caller (cloud-init, CI, the
  # bootstrap wizard). docker-compose.yml has fallback defaults via ${VAR:-...}
  # for everything below, so missing keys are harmless — but a value passed via
  # env would otherwise be lost on the next `docker compose` invocation.
  for key in IMAGE_TAG \
             TAKOPI_SHOW_RESUME_LINE \
             TAKOPI_DEFAULT_ENGINE \
             TAKOPI_DEFAULT_PROJECT \
             TAKOPI_TOPICS_ENABLED \
             TAKOPI_TOPICS_SCOPE \
             VOICE_TRANSCRIPTION_MODEL \
             VOICE_TRANSCRIPTION_BASE_URL \
             VOICE_TRANSCRIPTION_API_KEY \
             CLAUDE_ALLOWED_TOOLS \
             CLAUDE_DENIED_COMMANDS; do
    if [[ -n "${!key:-}" ]]; then
      printf '%s=%s\n' "$key" "${!key}" >>"$ENV_FILE"
    fi
  done

  ok "Configuration saved to .env"
fi

# --- Start the stack ---
echo ""

if [[ "$NONINTERACTIVE" == "1" ]]; then
  if [[ "${SKIP_START:-0}" != "1" ]]; then
    START_NOW=1
  else
    START_NOW=0
  fi
elif ask_yn START_STACK "Start the stack now?" "Y"; then
  START_NOW=1
else
  START_NOW=0
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
    info "TELEGRAM_CHAT_ID is unset — looking up /claim token from takopi logs..."
    CLAIM_LINE=""
    for _ in $(seq 1 30); do
      CLAIM_LINE=$(docker compose logs takopi 2>/dev/null \
        | grep -oE '/claim [A-Za-z0-9]+' | tail -n 1 || true)
      if [[ -n "$CLAIM_LINE" ]]; then
        break
      fi
      sleep 1
    done

    if [[ -n "$CLAIM_LINE" ]]; then
      echo ""
      echo "============================================================"
      echo "  CHAT BINDING REQUIRED"
      echo ""
      echo "  Open your Telegram chat with the bot and send EXACTLY:"
      echo ""
      echo "      $CLAIM_LINE"
      echo ""
      echo "  The bot will reply with confirmation and bind to that chat."
      echo "============================================================"
      echo ""
    else
      warn "Could not auto-extract the /claim token within 30s."
      info "Run this to see it manually:"
      info "  docker compose logs takopi | grep '/claim '"
      info "Then send the printed '/claim <token>' command to your bot."
    fi
  else
    info "Send a message to your Telegram bot to test."
    info "Follow logs: docker compose logs -f takopi"
  fi
  echo ""
  info "To set up Obsidian Sync later, run: ./scripts/auth-obsidian.sh login"
else
  echo ""
  info "To start later: cd $PROJECT_DIR && docker compose pull && docker compose up -d"
fi

# --- Seed vault/CLAUDE.local.md from template ---
# The agent reads vault/CLAUDE.md, which entrypoint.sh assembles from
# vault/CLAUDE.base.md (tracked) + vault/CLAUDE.local.md (per-install) +
# CLAUDE_EXTRA_INSTRUCTIONS env var. We drop a starter template into the
# vault on first setup so users have something obvious to edit.
CLAUDE_LOCAL="$PROJECT_DIR/vault/CLAUDE.local.md"
CLAUDE_LOCAL_TEMPLATE="$PROJECT_DIR/templates/CLAUDE.local.md.example"
if [[ ! -f "$CLAUDE_LOCAL" && -f "$CLAUDE_LOCAL_TEMPLATE" ]]; then
  cp "$CLAUDE_LOCAL_TEMPLATE" "$CLAUDE_LOCAL"
  echo ""
  info "Created $CLAUDE_LOCAL from template."
  info "Edit it to add your personal vault rules — they're appended to CLAUDE.md"
  info "on every container start. Send /new in Telegram to pick up changes."
fi

# --- Obsidian Sync setup ---
if [[ "$START_NOW" == "1" && "$NONINTERACTIVE" != "1" ]]; then
  echo ""
  echo "--- Obsidian Sync ---"
  echo ""
  info "Obsidian Sync connects this server's vault to your desktop and mobile Obsidian apps."
  info "Without it, anything the bot writes will only live on this server — you won't"
  info "see your notes in Obsidian. An active Obsidian Sync subscription is required."
  echo ""
  if ask_yn SETUP_OBSIDIAN_SYNC "Set up Obsidian Sync now?" "Y"; then
    # Redirect docker compose exec stdin to a real TTY so interactive
    # commands work even when this script was started under `curl | bash`
    # (where the script's own stdin is a pipe, not a terminal).
    # We pass stdin via a helper function to avoid eval with user-provided
    # strings (shell injection risk if vault names contain special chars).
    dc_exec() {
      if [[ -e /dev/tty ]]; then
        docker compose exec obsidian-headless "$@" </dev/tty
      else
        docker compose exec obsidian-headless "$@" </dev/null
      fi
    }

    echo ""
    info "Starting login — a URL will appear. Open it in a browser to authenticate,"
    info "then return here. The command exits automatically once login completes."
    dc_exec ob login

    echo ""
    info "Fetching your remote vaults..."
    # -T disables TTY allocation so output is capturable; sync-list-remote
    # is non-interactive so we don't need /dev/tty as stdin.
    VAULT_NAME_VAL=""
    if VAULTS_OUTPUT="$(docker compose exec -T obsidian-headless ob sync-list-remote 2>&1)"; then
      echo ""
      echo "$VAULTS_OUTPUT"
      echo ""

      # Parse quoted vault names from the output. The "ob sync-list-remote"
      # format is:  <id>  "Vault Name"  (Region)
      VAULT_NAMES=()
      while IFS= read -r line; do
        VAULT_NAMES+=("$line")
      done < <(printf '%s\n' "$VAULTS_OUTPUT" | grep -oE '"[^"]+"' | sed 's/^"//;s/"$//')

      if [[ ${#VAULT_NAMES[@]} -gt 0 ]]; then
        echo "Choose by number, or type the exact name:"
        for i in "${!VAULT_NAMES[@]}"; do
          printf "  %d) %s\n" "$((i+1))" "${VAULT_NAMES[i]}"
        done
        echo ""

        if [[ ${#VAULT_NAMES[@]} -eq 1 ]]; then
          VAULT_INPUT=$(ask OBSIDIAN_VAULT_NAME "Vault number or name (Enter for 1)" "1")
        else
          VAULT_INPUT=$(ask OBSIDIAN_VAULT_NAME "Vault number or exact name")
        fi

        if [[ "$VAULT_INPUT" =~ ^[0-9]+$ ]]; then
          idx=$((VAULT_INPUT - 1))
          if (( idx >= 0 && idx < ${#VAULT_NAMES[@]} )); then
            VAULT_NAME_VAL="${VAULT_NAMES[idx]}"
          else
            warn "Number out of range — skipping sync setup."
          fi
        else
          VAULT_NAME_VAL="$VAULT_INPUT"
        fi
      else
        VAULT_NAME_VAL=$(ask OBSIDIAN_VAULT_NAME "Vault name (exactly as shown above)")
      fi
    else
      warn "Failed to fetch vaults:"
      echo "$VAULTS_OUTPUT"
    fi

    if [[ -z "$VAULT_NAME_VAL" ]]; then
      warn "No vault selected — skipping sync setup."
      warn "Run './scripts/auth-obsidian.sh setup \"Your Vault Name\"' later to finish."
    else
      info "Configuring sync for vault: $VAULT_NAME_VAL"
      dc_exec ob sync-setup --vault "$VAULT_NAME_VAL" --path /vault

      if grep -q '^OBSIDIAN_AUTOSTART_SYNC=' "$ENV_FILE"; then
        sed -i 's/^OBSIDIAN_AUTOSTART_SYNC=.*/OBSIDIAN_AUTOSTART_SYNC=true/' "$ENV_FILE"
      else
        echo "OBSIDIAN_AUTOSTART_SYNC=true" >> "$ENV_FILE"
      fi

      info "Restarting obsidian-headless with continuous sync enabled..."
      docker compose up -d obsidian-headless
      ok "Obsidian Sync is active. Changes to your vault will sync automatically."
    fi
  else
    warn "Skipped. Your notes will only live on this server until sync is set up."
    warn "Run './scripts/auth-obsidian.sh login' later to enable sync with your Obsidian apps."
  fi
fi

echo ""
ok "Setup complete."

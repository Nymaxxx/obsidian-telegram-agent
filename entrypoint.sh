#!/usr/bin/env bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# --- graceful shutdown ---
shutdown() {
  log "received signal, shutting down..."
  kill -TERM "$TAKOPI_PID" 2>/dev/null || true
  wait "$TAKOPI_PID" 2>/dev/null || true
  exit 0
}
trap shutdown SIGTERM SIGINT

# --- permissions for volumes (run as root) ---
mkdir -p /home/agent/.takopi /work/repos
chown -R agent:agent /home/agent/.takopi /work/repos || true

# --- helper: build TOML arrays from env ---
to_toml_int_array() {
  local s="${1:-}"
  s="${s// /}"
  if [[ -z "$s" ]]; then
    echo "[]"
    return
  fi
  IFS=',' read -ra parts <<< "$s"
  local out="["
  local first=1
  for p in "${parts[@]}"; do
    [[ -z "$p" ]] && continue
    if [[ $first -eq 1 ]]; then
      out+="$p"; first=0
    else
      out+=", $p"
    fi
  done
  out+="]"
  echo "$out"
}

to_toml_str_array() {
  local s="${1:-}"
  s="${s// /}"
  if [[ -z "$s" ]]; then
    echo '["Bash","Read","Edit","Write"]'
    return
  fi
  IFS=',' read -ra parts <<< "$s"
  local out="["
  local first=1
  for p in "${parts[@]}"; do
    [[ -z "$p" ]] && continue
    if [[ $first -eq 1 ]]; then
      out+="\"$p\""; first=0
    else
      out+=", \"$p\""
    fi
  done
  out+="]"
  echo "$out"
}

# --- validate required env ---
: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required}"
: "${TAKOPI_TELEGRAM_BOT_TOKEN:?TAKOPI_TELEGRAM_BOT_TOKEN is required}"
: "${TAKOPI_TELEGRAM_CHAT_ID:?TAKOPI_TELEGRAM_CHAT_ID is required}"
: "${GH_TOKEN:?GH_TOKEN is required}"

TAKOPI_CFG="/home/agent/.takopi/takopi.toml"

DEFAULT_ENGINE="${TAKOPI_DEFAULT_ENGINE:-claude}"
SESSION_MODE="${TAKOPI_SESSION_MODE:-chat}"
SHOW_RESUME_LINE="${TAKOPI_SHOW_RESUME_LINE:-true}"

CLAUDE_MODEL="${TAKOPI_CLAUDE_MODEL:-claude-opus-4-6}"
CLAUDE_ALLOWED_TOOLS="${TAKOPI_CLAUDE_ALLOWED_TOOLS:-Bash,Read,Edit,Write}"
CLAUDE_SKIP="${TAKOPI_CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS:-false}"
CLAUDE_USE_API_BILLING="${TAKOPI_CLAUDE_USE_API_BILLING:-true}"

ALLOWED_USER_IDS="$(to_toml_int_array "${TAKOPI_ALLOWED_USER_IDS:-}")"
ALLOWED_TOOLS="$(to_toml_str_array "${CLAUDE_ALLOWED_TOOLS}")"

# --- git auth (restricted permissions) ---
cat >/tmp/gitconfig <<EOF
[url "https://x-access-token:${GH_TOKEN}@github.com/"]
    insteadOf = https://github.com/
EOF
chmod 600 /tmp/gitconfig
export GIT_CONFIG_GLOBAL=/tmp/gitconfig
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0

# --- always regenerate takopi config from env vars ---
log "writing takopi config from environment"
cat >"$TAKOPI_CFG" <<EOF
watch_config = true
transport = "telegram"
default_engine = "${DEFAULT_ENGINE}"

[transports.telegram]
bot_token = "${TAKOPI_TELEGRAM_BOT_TOKEN}"
chat_id = ${TAKOPI_TELEGRAM_CHAT_ID}
allowed_user_ids = ${ALLOWED_USER_IDS}
session_mode = "${SESSION_MODE}"
show_resume_line = ${SHOW_RESUME_LINE}

[claude]
model = "${CLAUDE_MODEL}"
allowed_tools = ${ALLOWED_TOOLS}
dangerously_skip_permissions = ${CLAUDE_SKIP}
use_api_billing = ${CLAUDE_USE_API_BILLING}
EOF
chown agent:agent "$TAKOPI_CFG" || true

# --- optional bootstrap repos into /work/repos and register as projects ---
# Format: "owner/repo:alias,owner/repo2"
if [[ -n "${GITHUB_REPOS:-}" ]]; then
  IFS=',' read -ra repos <<< "${GITHUB_REPOS}"
  for item in "${repos[@]}"; do
    item="$(echo "$item" | xargs)"
    [[ -z "$item" ]] && continue

    repo="$item"
    alias=""
    if [[ "$item" == *":"* ]]; then
      repo="${item%%:*}"
      alias="${item##*:}"
    else
      alias="${item##*/}"
    fi

    target="/work/repos/${alias}"
    if [[ ! -d "$target/.git" ]]; then
      log "cloning ${repo} -> ${target}"
      if ! su -s /bin/bash agent -c "git clone https://github.com/${repo}.git '${target}'"; then
        log "WARNING: failed to clone ${repo}"
        continue
      fi
    else
      log "repo exists: ${target}, pulling latest"
      su -s /bin/bash agent -c "cd '${target}' && git pull --ff-only" \
        || log "WARNING: failed to pull ${target} (may have local changes)"
    fi

    log "registering project: ${alias}"
    if ! su -s /bin/bash agent -c "cd '${target}' && takopi init '${alias}'"; then
      log "WARNING: failed to register project ${alias}"
    fi
  done
fi

# --- start takopi (as agent) ---
log "starting takopi"
su -s /bin/bash agent -c "takopi" &
TAKOPI_PID=$!
wait "$TAKOPI_PID"

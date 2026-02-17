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
mkdir -p /home/agent/.takopi /home/agent/.claude/tasks /work/repos
chown -R agent:agent /home/agent/.takopi /home/agent/.claude /work/repos || true

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

VOICE_ENABLED="${VOICE_TRANSCRIPTION:-false}"
VOICE_MODEL="${VOICE_TRANSCRIPTION_MODEL:-gpt-4o-mini-transcribe}"
VOICE_BASE_URL="${VOICE_TRANSCRIPTION_BASE_URL:-}"
VOICE_API_KEY="${VOICE_TRANSCRIPTION_API_KEY:-}"

# --- git auth (agent-owned, not world-readable) ---
GITCONFIG="/home/agent/.gitconfig"
cat >"$GITCONFIG" <<EOF
[url "https://x-access-token:${GH_TOKEN}@github.com/"]
    insteadOf = https://github.com/
[user]
    name = takopi-agent
    email = takopi-agent@noreply.github.com
EOF
chown agent:agent "$GITCONFIG"
chmod 600 "$GITCONFIG"
export GIT_CONFIG_GLOBAL="$GITCONFIG"
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_TERMINAL_PROMPT=0

# --- always regenerate takopi config from env vars ---
log "writing takopi config from environment"

# Build voice transcription config block
VOICE_CFG=""
if [[ "$VOICE_ENABLED" == "true" ]]; then
  VOICE_CFG="voice_transcription = true
voice_transcription_model = \"${VOICE_MODEL}\""
  if [[ -n "$VOICE_BASE_URL" ]]; then
    VOICE_CFG="${VOICE_CFG}
voice_transcription_base_url = \"${VOICE_BASE_URL}\""
  fi
  if [[ -n "$VOICE_API_KEY" ]]; then
    VOICE_CFG="${VOICE_CFG}
voice_transcription_api_key = \"${VOICE_API_KEY}\""
  fi
  log "voice transcription enabled: model=${VOICE_MODEL}"
else
  VOICE_CFG="voice_transcription = false"
fi

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
${VOICE_CFG}

[claude]
model = "${CLAUDE_MODEL}"
allowed_tools = ${ALLOWED_TOOLS}
dangerously_skip_permissions = ${CLAUDE_SKIP}
use_api_billing = ${CLAUDE_USE_API_BILLING}
EOF
chown agent:agent "$TAKOPI_CFG" || true

# --- helper: auto-detect project type and install dependencies ---
auto_setup_repo() {
  local dir="$1"
  log "auto-setup: detecting project type in ${dir}"

  # Custom setup script takes priority
  if [[ -f "${dir}/.takopi-setup.sh" ]]; then
    log "auto-setup: running .takopi-setup.sh"
    su -s /bin/bash agent -c "cd '${dir}' && bash .takopi-setup.sh" \
      || log "WARNING: .takopi-setup.sh failed in ${dir}"
    return
  fi

  # Node.js (package.json)
  if [[ -f "${dir}/package.json" ]]; then
    if [[ -f "${dir}/package-lock.json" ]]; then
      log "auto-setup: npm ci"
      su -s /bin/bash agent -c "cd '${dir}' && npm ci --ignore-scripts 2>&1 | tail -1" \
        || log "WARNING: npm ci failed in ${dir}"
    elif [[ -f "${dir}/yarn.lock" ]]; then
      log "auto-setup: yarn install --frozen-lockfile"
      su -s /bin/bash agent -c "cd '${dir}' && yarn install --frozen-lockfile 2>&1 | tail -1" \
        || log "WARNING: yarn install failed in ${dir}"
    elif [[ -f "${dir}/pnpm-lock.yaml" ]]; then
      log "auto-setup: pnpm install --frozen-lockfile"
      su -s /bin/bash agent -c "cd '${dir}' && pnpm install --frozen-lockfile 2>&1 | tail -1" \
        || log "WARNING: pnpm install failed in ${dir}"
    else
      log "auto-setup: npm install"
      su -s /bin/bash agent -c "cd '${dir}' && npm install 2>&1 | tail -1" \
        || log "WARNING: npm install failed in ${dir}"
    fi
  fi

  # Python (pyproject.toml / requirements.txt)
  if [[ -f "${dir}/pyproject.toml" ]]; then
    log "auto-setup: uv sync"
    su -s /bin/bash agent -c "cd '${dir}' && uv sync 2>&1 | tail -1" \
      || log "WARNING: uv sync failed in ${dir}"
  elif [[ -f "${dir}/requirements.txt" ]]; then
    log "auto-setup: uv pip install -r requirements.txt"
    su -s /bin/bash agent -c "cd '${dir}' && uv pip install -r requirements.txt 2>&1 | tail -1" \
      || log "WARNING: pip install failed in ${dir}"
  fi

  # Go (go.mod)
  if [[ -f "${dir}/go.mod" ]]; then
    log "auto-setup: go mod download"
    su -s /bin/bash agent -c "cd '${dir}' && go mod download 2>&1 | tail -1" \
      || log "WARNING: go mod download failed in ${dir}"
  fi

  # Rust (Cargo.toml)
  if [[ -f "${dir}/Cargo.toml" ]]; then
    log "auto-setup: cargo fetch"
    su -s /bin/bash agent -c "cd '${dir}' && cargo fetch 2>&1 | tail -1" \
      || log "WARNING: cargo fetch failed in ${dir}"
  fi
}

# --- helper: deploy CLAUDE.md template into a repo ---
deploy_claude_md() {
  local dir="$1"
  local template="/opt/templates/CLAUDE.md"

  if [[ -f "${dir}/CLAUDE.md" ]]; then
    log "CLAUDE.md already exists in ${dir}, keeping repo version"
  else
    cp "$template" "${dir}/CLAUDE.md"
    chown agent:agent "${dir}/CLAUDE.md"
    log "deployed CLAUDE.md template to ${dir}"
  fi
}

# --- optional bootstrap repos into /work/repos and register as projects ---
# Format: "owner/repo:alias,owner/repo2"
AUTO_SETUP="${AUTO_SETUP_REPOS:-true}"

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

    # deploy CLAUDE.md (respects existing per-repo version)
    deploy_claude_md "$target"

    # auto-detect and install dependencies
    if [[ "$AUTO_SETUP" == "true" ]]; then
      auto_setup_repo "$target"
    fi

    log "registering project: ${alias}"
    if ! su -s /bin/bash agent -c "cd '${target}' && takopi init '${alias}'"; then
      log "WARNING: failed to register project ${alias}"
    fi
  done
fi

# --- Claude Code Tasks (persistent cross-session task tracking) ---
export CLAUDE_CODE_TASK_LIST_ID="${CLAUDE_CODE_TASK_LIST_ID:-takopi-homelab}"
log "tasks enabled: list_id=${CLAUDE_CODE_TASK_LIST_ID}, storage=/home/agent/.claude/tasks/"

# --- start takopi (as agent) ---
log "starting takopi"
su -s /bin/bash agent -c "CLAUDE_CODE_TASK_LIST_ID='${CLAUDE_CODE_TASK_LIST_ID}' takopi" &
TAKOPI_PID=$!
wait "$TAKOPI_PID"

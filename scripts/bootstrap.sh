#!/usr/bin/env bash
# bootstrap.sh — one-command VPS install for Obsidian Telegram Agent.
#
# Interactive (newcomer):
#   curl -fsSL https://raw.githubusercontent.com/Nymaxxx/obsidian-telegram-agent/main/scripts/bootstrap.sh | bash
#
# Non-interactive (cloud-init / CI):
#   curl -fsSL https://raw.githubusercontent.com/Nymaxxx/obsidian-telegram-agent/main/scripts/bootstrap.sh \
#     | env TELEGRAM_BOT_TOKEN=... TELEGRAM_CHAT_ID=... ANTHROPIC_API_KEY=... \
#           NONINTERACTIVE=1 BACKUP_ACKNOWLEDGED=1 bash
#
# Don't trust curl-pipe-bash? Download, review, then run:
#   curl -fsSL https://raw.githubusercontent.com/Nymaxxx/obsidian-telegram-agent/main/scripts/bootstrap.sh -o bootstrap.sh
#   less bootstrap.sh
#   bash bootstrap.sh

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Nymaxxx/obsidian-telegram-agent.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/obsidian-telegram-agent}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[bootstrap]${NC}  $*"; }
ok()    { echo -e "${GREEN}[bootstrap]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[bootstrap]${NC}  $*"; }
error() { echo -e "${RED}[bootstrap]${NC}  $*" >&2; exit 1; }

# Use sudo only if we're not already root.
if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=""
else
  if ! command -v sudo >/dev/null 2>&1; then
    error "sudo is required when not running as root."
  fi
  SUDO="sudo"
fi

echo ""
echo "============================================="
echo "  Obsidian Telegram Agent — Bootstrap"
echo "============================================="
echo ""
info "Repo:        $REPO_URL"
info "Install dir: $INSTALL_DIR"
echo ""

# --- 1. OS check ---
if [[ "$(uname -s)" != "Linux" ]]; then
  error "This bootstrap targets Linux VPS. Detected: $(uname -s). On macOS, clone manually and run 'make setup'."
fi

# --- 2. Detect package manager and install git + curl if missing ---
ensure_pkg() {
  local cmd="$1" pkg="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  info "Installing $pkg..."
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y --no-install-recommends "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y "$pkg"
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache "$pkg"
  else
    error "Unsupported package manager. Install '$pkg' manually and re-run."
  fi
}

ensure_pkg curl curl
ensure_pkg git git
ok "git and curl are available."

# --- 3. Install Docker if missing ---
if ! command -v docker >/dev/null 2>&1; then
  info "Docker not found — installing via get.docker.com..."
  curl -fsSL https://get.docker.com | $SUDO sh
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now docker || warn "Could not enable docker via systemctl (non-systemd host?). Continuing."
  fi
  ok "Docker installed."
else
  ok "Docker already installed."
fi

if ! docker compose version >/dev/null 2>&1; then
  error "Docker Compose plugin is not available. Update Docker or install docker-compose-plugin manually."
fi

# --- 4. Clone or update the repo ---
if [[ -d "$INSTALL_DIR/.git" ]]; then
  info "Existing clone at $INSTALL_DIR — updating with git pull..."
  before_sha="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  git -C "$INSTALL_DIR" fetch --quiet origin
  if ! git -C "$INSTALL_DIR" pull --ff-only --quiet; then
    warn "============================================================"
    warn "  Could not fast-forward (uncommitted changes or non-FF)."
    warn "  Continuing with the EXISTING checkout. The repo may be"
    warn "  stale — see the commit SHA below to confirm what's running."
    warn "  To force-update: resolve locally, or rerun with"
    warn "  INSTALL_DIR=<fresh path>."
    warn "============================================================"
  fi
  after_sha="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  if [[ "$before_sha" == "$after_sha" ]]; then
    ok "Running from commit $after_sha (unchanged)."
  else
    ok "Updated $before_sha → $after_sha."
  fi
elif [[ -d "$INSTALL_DIR" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
  error "Directory $INSTALL_DIR exists and is not a git checkout. Move it aside or set INSTALL_DIR to a fresh path."
else
  info "Cloning $REPO_URL → $INSTALL_DIR ..."
  git clone --quiet "$REPO_URL" "$INSTALL_DIR"
  fresh_sha="$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  ok "Clone complete (commit $fresh_sha)."
fi

# --- 5. Hand off to install.sh ---
INSTALL_SCRIPT="$INSTALL_DIR/scripts/install.sh"
if [[ ! -x "$INSTALL_SCRIPT" ]]; then
  if [[ -f "$INSTALL_SCRIPT" ]]; then
    chmod +x "$INSTALL_SCRIPT"
  else
    error "Missing $INSTALL_SCRIPT — repo layout looks broken."
  fi
fi

cd "$INSTALL_DIR"
info "Handing off to scripts/install.sh ..."
echo ""

# Inherit all env vars (TELEGRAM_BOT_TOKEN, etc.) — install.sh reads them.
exec "$INSTALL_SCRIPT" "$@"

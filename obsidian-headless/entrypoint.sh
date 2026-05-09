#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/state}"
mkdir -p "$HOME" /vault

if [[ $# -gt 0 ]]; then
  exec "$@"
fi

if [[ "${OBSIDIAN_AUTOSTART_SYNC:-false}" == "true" ]]; then
  if ob sync-status --path /vault >/dev/null 2>&1; then
    echo "Starting continuous Obsidian sync for /vault"
    exec ob sync --continuous --path /vault
  else
    echo "Obsidian Headless is installed but sync is not configured yet."
    echo "Run: docker compose exec obsidian-headless ob login"
    echo "Then: docker compose exec obsidian-headless ob sync-setup --vault \"<Vault Name>\" --path /vault"
    exec sleep infinity
  fi
fi

echo "Obsidian Headless is idle. Set OBSIDIAN_AUTOSTART_SYNC=true after setup."
exec sleep infinity

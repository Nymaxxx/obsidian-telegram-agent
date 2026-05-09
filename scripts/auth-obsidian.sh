#!/usr/bin/env bash
set -euo pipefail

# Always run docker compose from the project root, regardless of where
# the caller invoked this script from.
cd "$(dirname "$0")/.."

cmd="${1:-login}"
shift || true

case "$cmd" in
  login)
    docker compose exec obsidian-headless ob login
    ;;
  list)
    docker compose exec obsidian-headless ob sync-list-remote
    ;;
  setup)
    vault_name="${1:-}"
    if [[ -z "$vault_name" ]]; then
      echo 'Usage: ./scripts/auth-obsidian.sh setup "My Vault"'
      exit 1
    fi
    docker compose exec obsidian-headless ob sync-setup --vault "$vault_name" --path /vault
    ;;
  status)
    docker compose exec obsidian-headless ob sync-status --path /vault
    ;;
  sync)
    docker compose exec obsidian-headless ob sync --path /vault
    ;;
  continuous)
    docker compose exec obsidian-headless ob sync --continuous --path /vault
    ;;
  *)
    echo "Unknown command: $cmd"
    echo "Use one of: login | list | setup | status | sync | continuous"
    exit 1
    ;;
esac

#!/usr/bin/env bash
set -euo pipefail

mkdir -p sing-box takopi-state obsidian-state vault/Inbox vault/Daily vault/Projects vault/templates

echo "Created local state and vault directories."

if [[ ! -e /dev/net/tun ]]; then
  echo
  echo "WARNING: /dev/net/tun is missing on this host. sing-box TUN mode will not work until TUN is available."
  exit 1
fi

echo "/dev/net/tun is available."

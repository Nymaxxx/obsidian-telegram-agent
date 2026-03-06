#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
OUT_FILE="${ROOT_DIR}/sing-box/config.json"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing .env. Copy .env.example to .env first."
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

mkdir -p "${ROOT_DIR}/sing-box"

mode="${VLESS_MODE:-tls}"
server="${VLESS_SERVER:-}"
port="${VLESS_PORT:-443}"
uuid="${VLESS_UUID:-}"
sni="${VLESS_SNI:-}"
flow="${VLESS_FLOW:-}"
public_key="${VLESS_REALITY_PUBLIC_KEY:-}"
short_id="${VLESS_REALITY_SHORT_ID:-}"

if [[ -z "$server" || -z "$uuid" || -z "$sni" ]]; then
  echo "VLESS_SERVER, VLESS_UUID, and VLESS_SNI must be set in .env"
  exit 1
fi

if [[ "$mode" == "reality" ]]; then
  if [[ -z "$public_key" || -z "$short_id" ]]; then
    echo "For VLESS_MODE=reality you must set VLESS_REALITY_PUBLIC_KEY and VLESS_REALITY_SHORT_ID"
    exit 1
  fi
  : "${flow:=xtls-rprx-vision}"
  cat > "$OUT_FILE" <<JSON
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "cloudflare",
        "address": "https://1.1.1.1/dns-query"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": [
        "172.19.0.1/30"
      ],
      "mtu": 1500,
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true,
      "stack": "system",
      "route_exclude_address": [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16"
      ]
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "$server",
      "server_port": $port,
      "uuid": "$uuid",
      "flow": "$flow",
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "reality": {
          "enabled": true,
          "public_key": "$public_key",
          "short_id": "$short_id"
        },
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "vless-out"
  }
}
JSON
else
  cat > "$OUT_FILE" <<JSON
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "dns": {
    "servers": [
      {
        "tag": "cloudflare",
        "address": "https://1.1.1.1/dns-query"
      }
    ]
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "tun0",
      "address": [
        "172.19.0.1/30"
      ],
      "mtu": 1500,
      "auto_route": true,
      "auto_redirect": true,
      "strict_route": true,
      "stack": "system",
      "route_exclude_address": [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16"
      ]
    }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "vless-out",
      "server": "$server",
      "server_port": $port,
      "uuid": "$uuid",
      "flow": "$flow",
      "tls": {
        "enabled": true,
        "server_name": "$sni",
        "utls": {
          "enabled": true,
          "fingerprint": "chrome"
        }
      }
    },
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "vless-out"
  }
}
JSON
fi

echo "Rendered $OUT_FILE for mode=$mode"

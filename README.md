# Takopi + Claude + Obsidian Sync + VLESS sidecar

A homelab-ready stack for controlling an Obsidian vault from Telegram with text or voice messages.

The design is:
- **Takopi** handles Telegram chat, routing, and voice-note transcription.
- **Claude Code CLI** is the engine Takopi calls under the hood.
- **sing-box** is a **VLESS sidecar** in TUN mode, so all Takopi outbound traffic goes through your VLESS tunnel.
- **Obsidian Headless** keeps the same vault synced through **Obsidian Sync**.
- **Obsidian desktop/mobile** remains your normal UI for reading and manual editing.

## What this repository gives you

- `docker-compose.yml`
- a `takopi` image with Takopi + Claude Code CLI preinstalled
- an `obsidian-headless` image with Obsidian Headless preinstalled
- `sing-box` VLESS config templates
- helper scripts to render `sing-box/config.json`
- a starter vault layout
- a README with the full bring-up flow

## Architecture

```text
Telegram text / voice
        |
        v
      Takopi  --(all outbound traffic via sing-box/VLESS)--> Telegram / Claude / transcription API
        |
        v
   /vault (shared bind mount)
        |
        +--> Obsidian Headless --(Obsidian Sync)--> your desktop / mobile Obsidian apps
```

## Important caveats

- **Obsidian Headless is open beta.** Back up the vault before using it.
- **Do not use both desktop Sync and Headless Sync on the same device.** Use only one sync method per device.
- **Takopi shells out to local engine CLIs.** In this stack, that engine is `claude`.
- **Takopi cannot answer Claude permission prompts in non-interactive mode.** Keep allowed tools narrow and verify Claude permissions before relying on unattended runs.
- The provided `sing-box` templates cover **VLESS + TLS** and **VLESS + REALITY**. If you use **WS/gRPC** or a more unusual transport, adjust the config manually.

## Prerequisites

You need:
- a Linux host with Docker and Docker Compose
- `/dev/net/tun` available on the host
- a VLESS endpoint you control or trust
- a Telegram bot token and the chat id where Takopi should listen
- access to Claude Code
- an Obsidian Sync subscription if you want server-side sync
- optionally an OpenAI key or a local OpenAI-compatible Whisper endpoint for Telegram voice-note transcription

## Repository layout

```text
.
├─ docker-compose.yml
├─ .env.example
├─ AGENTS.md
├─ README.md
├─ scripts/
│  ├─ bootstrap.sh
│  ├─ render-singbox-config.sh
│  ├─ auth-claude.sh
│  └─ auth-obsidian.sh
├─ sing-box/
│  ├─ config.tls.json.template
│  └─ config.reality.json.template
├─ takopi/
│  ├─ Dockerfile
│  └─ entrypoint.sh
├─ obsidian-headless/
│  ├─ Dockerfile
│  └─ entrypoint.sh
└─ vault/
   ├─ Inbox/
   ├─ Daily/
   ├─ Projects/
   └─ templates/
      └─ note.md
```

## Quick start

### 1. Copy the environment template

```bash
cp .env.example .env
```

Fill in at least:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`
- `VLESS_*`

If you want voice notes, also fill in either:
- `OPENAI_API_KEY`, or
- `VOICE_TRANSCRIPTION_BASE_URL` and optionally `VOICE_TRANSCRIPTION_API_KEY`

### 2. Render the VLESS sidecar config

For plain TLS VLESS:

```bash
./scripts/render-singbox-config.sh
```

If `VLESS_MODE=reality`, the same script renders a REALITY config instead.

This writes `sing-box/config.json`, which is the file actually used by the container.

### 3. Create directories and check host prerequisites

```bash
./scripts/bootstrap.sh
```

This creates the local state directories and reminds you about `/dev/net/tun`.

### 4. Build and start the stack

```bash
docker compose up -d --build
```

At this point:
- `sing-box` should come up with your VLESS client config
- `takopi` should start and render `takopi.toml` into `/state/.takopi/takopi.toml`
- `obsidian-headless` will stay idle until sync is configured or `OBSIDIAN_AUTOSTART_SYNC=true`

### 5. Authenticate Claude Code

#### Option A: interactive Claude login

```bash
./scripts/auth-claude.sh
```

This opens an interactive `claude` session inside the `takopi` container.

#### Option B: API billing

Set these in `.env`:

```env
CLAUDE_USE_API_BILLING=true
ANTHROPIC_API_KEY=...
```

Then restart `takopi`:

```bash
docker compose up -d takopi
```

### 6. Configure Obsidian Headless Sync

Login:

```bash
./scripts/auth-obsidian.sh login
```

List remote vaults:

```bash
./scripts/auth-obsidian.sh list
```

Attach the local `/vault` directory to your remote vault:

```bash
./scripts/auth-obsidian.sh setup "My Vault"
```

Then enable continuous sync by setting in `.env`:

```env
OBSIDIAN_AUTOSTART_SYNC=true
```

Restart the service:

```bash
docker compose up -d obsidian-headless
```

### 7. Test the bot

Text:

```text
создай заметку в Inbox с названием Идея про homelab memory
```

Or explicitly target the configured project:

```text
/obsidian создай заметку в Inbox с названием Идея про homelab memory
```

Voice notes also work if you enabled transcription.

## How Takopi is configured here

The `takopi` container renders this kind of config into `/state/.takopi/takopi.toml` at startup:

- `default_engine = "claude"`
- `default_project = "obsidian"`
- `transport = "telegram"`
- Telegram bot token and chat id under `[transports.telegram]`
- project alias `obsidian` bound to `/vault`
- Claude runner settings under `[claude]`

That means you can talk to the bot in three main ways:
- **plain text** in the configured chat
- **voice notes**, which Takopi transcribes into normal text messages
- **explicit directives** such as `/claude` or `/obsidian`

Examples:

```text
/claude суммаризируй папку Projects
/obsidian создай заметку в Inbox с названием Встреча с юристом
/obsidian перепиши заметку Projects/OSINT.md в более продуктовый стиль
```

## How the VLESS sidecar works

`takopi` runs with:

```yaml
network_mode: "service:sing-box"
```

So `takopi` uses the network namespace of `sing-box`. In practice this means:
- Takopi has **no separate Docker network of its own**
- all Takopi outbound traffic goes through the VLESS tunnel handled by `sing-box`
- the shared vault mount still works normally because volumes are local filesystem mounts, not network traffic

By design in this repo, **Obsidian Headless does not use the VLESS sidecar**. That keeps sync behavior simpler and easier to debug.

## Local transcription / local LAN services

The `sing-box` TUN config excludes common RFC1918 private ranges from redirection:
- `10.0.0.0/8`
- `172.16.0.0/12`
- `192.168.0.0/16`
- `127.0.0.0/8`

That makes it easier to talk from Takopi to a **local Whisper server** or another service on your LAN without forcing those requests through VLESS.

If your local network uses different ranges, adjust `route_exclude_address` in `sing-box/config.json`.

## Typical operations

### Follow logs

```bash
docker compose logs -f sing-box
docker compose logs -f takopi
docker compose logs -f obsidian-headless
```

### Check the generated Takopi config

```bash
docker compose exec takopi sh -lc 'cat /state/.takopi/takopi.toml'
```

### Check the external IP seen by Takopi

```bash
docker compose exec takopi sh -lc 'which curl >/dev/null 2>&1 || (apt-get update && apt-get install -y curl); curl https://ifconfig.me'
```

The IP should be the one exposed by your VLESS exit, not the host's direct IP.

### Test Obsidian sync status

```bash
docker compose exec obsidian-headless ob sync-status --path /vault
```

## Recommended hardening and operational notes

- Keep the allowed Claude tool set narrow.
- Put the vault under git if you want an easy audit trail of agent edits.
- Do not let the bot edit `.obsidian/` by default.
- Start with `Inbox/`, `Daily/`, and `Projects/` only.
- If you use a group chat, consider enabling Takopi trigger mode `mentions` after initial setup.

## What is not included yet

This repository does **not** implement custom safe slash-commands like:
- `/capture`
- `/append`
- `/summarize`
- `/revise`

Right now this stack relies on general Claude/Takopi behavior over the vault path. That is good for an MVP. If you want stricter and safer vault operations, the next step is adding a small Takopi plugin or wrapper scripts for note-specific commands.

## Sources

This repo is based on the current upstream behavior of:
- Takopi install, config, projects, Telegram transport, voice notes, and Claude runner
- Obsidian Headless and Headless Sync
- sing-box Docker install, VLESS outbound, and TUN behavior
- Claude Code install, settings path, and authentication / permissions model

See these upstream docs when you adapt the stack:
- Takopi: https://takopi.dev/
- Obsidian Headless / Sync: https://help.obsidian.md/
- sing-box: https://sing-box.sagernet.org/
- Claude Code: https://docs.anthropic.com/ and https://code.claude.com/

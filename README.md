# Takopi + Claude + Obsidian Sync

A homelab-ready stack for controlling an Obsidian vault from Telegram with text or voice messages.

- **Takopi** handles Telegram chat, routing, and voice-note transcription.
- **Claude Code CLI** is the engine Takopi calls under the hood.
- **Obsidian Headless** keeps the same vault synced through **Obsidian Sync**.
- **Obsidian desktop/mobile** remains your normal UI for reading and manual editing.

## What this repository gives you

- `docker-compose.yml`
- a `takopi` image with Takopi + Claude Code CLI preinstalled
- an `obsidian-headless` image with Obsidian Headless preinstalled
- a starter vault layout
- a GitHub Actions workflow for automatic deploys on every push to `main`
- a README with the full bring-up flow

## Architecture

```text
Telegram text / voice
        |
        v
      Takopi  --> Telegram / Claude / transcription API
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

## Prerequisites

You need:
- a Linux VPS with Docker and Docker Compose (any European VPS works fine)
- a Telegram bot token and the chat id where Takopi should listen
- access to Claude Code (interactive login or Anthropic API key)
- an Obsidian Sync subscription if you want server-side sync
- optionally an OpenAI key or a local OpenAI-compatible Whisper endpoint for voice-note transcription

## Repository layout

```text
.
├─ .github/
│  └─ workflows/
│     └─ deploy.yml        ← auto-deploy on push to main
├─ docker-compose.yml
├─ .env.example
├─ README.md
├─ Makefile
├─ scripts/
│  ├─ auth-claude.sh       ← one-time Claude login
│  └─ auth-obsidian.sh     ← one-time Obsidian Sync login
├─ takopi/
│  ├─ Dockerfile
│  └─ entrypoint.sh
├─ obsidian-headless/
│  ├─ Dockerfile
│  └─ entrypoint.sh
└─ vault/
   ├─ CLAUDE.md              ← agent instructions (read by Claude Code at /vault)
   ├─ 00 Projects/
   ├─ 10 Areas/
   │  ├─ Inbox/
   │  ├─ Todo/
   │  │  ├─ Daily notes/
   │  │  ├─ Long goals/
   │  │  └─ Short goals/
   │  └─ Общие заметки/
   ├─ 20 Resources/
   ├─ 90 Archive/          ← hidden from takopi via tmpfs overlay
   └─ templates/
      └─ note.md
```

## Quick start

### 1. Clone the repo on the VPS

```bash
git clone https://github.com/your-user/takopi-claude-homelab ~/takopi-claude-homelab
cd ~/takopi-claude-homelab
```

### 2. Create state directories

```bash
mkdir -p takopi-state obsidian-state
```

### 3. Build and start the stack

```bash
docker compose up -d --build
```

At this point:
- `takopi` starts and renders `takopi.toml` into `/state/.takopi/takopi.toml`
- `obsidian-headless` stays idle until sync is configured or `OBSIDIAN_AUTOSTART_SYNC=true`

You still need to authenticate Claude and optionally Obsidian Sync — see below.

### 4. Authenticate Claude Code

#### Option A: interactive Claude login

```bash
./scripts/auth-claude.sh
```

This opens an interactive `claude` session inside the `takopi` container. The session token is persisted in `takopi-state/` and survives container restarts and redeploys.

#### Option B: API billing

Set these in `.env`:

```env
CLAUDE_USE_API_BILLING=true
ANTHROPIC_API_KEY=sk-ant-...
```

Then restart `takopi`:

```bash
docker compose up -d takopi
```

### 5. Configure Obsidian Headless Sync

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

### 6. Test the bot

Text:

```text
создай заметку в 10 Areas/Inbox с названием Идея про homelab
```

Or explicitly target the configured project:

```text
/obsidian создай заметку в 10 Areas/Inbox с названием Идея про homelab
```

Voice notes also work if you enabled transcription.

## Auto-deploy with GitHub Actions

Every push to `main` triggers the deploy workflow in `.github/workflows/deploy.yml`. It SSHs into the VPS, pulls the latest code, writes `.env` from a GitHub Secret, and runs `docker compose up --build -d`.

The workflow sends **Telegram notifications** on success and failure using the same bot token and chat id from your `ENV_FILE` secret — no extra secrets needed.

### Setting up GitHub Secrets

Go to your GitHub repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**.

Add the following secrets:

| Secret | Value |
|---|---|
| `VPS_HOST` | IP address or hostname of your VPS |
| `VPS_USER` | SSH username (e.g. `root` or `ubuntu`) |
| `VPS_SSH_KEY` | Private SSH key (the full contents of `~/.ssh/id_ed25519`) |
| `ENV_FILE` | Full contents of your `.env` file |

#### Generating an SSH key for deploys (if you don't have one)

On your local machine:

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/deploy_key -N ""
```

Copy the public key to the VPS:

```bash
ssh-copy-id -i ~/.ssh/deploy_key.pub user@your-vps
```

Paste the contents of `~/.ssh/deploy_key` (private key) into the `VPS_SSH_KEY` secret.

#### The ENV_FILE secret

Copy the contents of your filled-in `.env` file and paste them as the value of the `ENV_FILE` secret. The deploy workflow writes this to `.env` on the VPS on every deploy, so you only need to update the secret when your config changes — you never need to SSH in just to edit `.env`.

Start from the template:

```bash
cat .env.example
```

Fill in at least:
- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_CHAT_ID`

If you use API billing for Claude, also set:
- `CLAUDE_USE_API_BILLING=true`
- `ANTHROPIC_API_KEY=sk-ant-...`

If you want voice notes, also fill in either:
- `OPENAI_API_KEY`, or
- `VOICE_TRANSCRIPTION_BASE_URL` and optionally `VOICE_TRANSCRIPTION_API_KEY`

### What persists between deploys

| Path | Contents | Survives `git pull` |
|---|---|---|
| `./vault/` | Your Obsidian notes | Yes — notes (`.md`) and `.obsidian/` are gitignored; `CLAUDE.md`, folder structure, and templates are tracked |
| `./takopi-state/` | Claude auth token | Yes — gitignored |
| `./obsidian-state/` | Obsidian Sync auth | Yes — gitignored |

You only need to run `auth-claude.sh` and `auth-obsidian.sh` **once** after the initial setup. All subsequent deploys preserve those auth states.

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
/claude суммаризируй папку 00 Projects
/obsidian создай заметку в 10 Areas/Inbox с названием Встреча с юристом
/obsidian перепиши заметку 00 Projects/OSINT mindset/OSINT.md в более продуктовый стиль
```

## Sessions and conversation flow

This stack uses `session_mode = "chat"`, which means Takopi **automatically resumes** the previous Claude session on every new message. You do not need to do anything special — just keep sending messages and Claude remembers the context.

### How it works under the hood

1. You send a message in Telegram.
2. Takopi passes it to `claude -p "your message" --resume <session_id>`.
3. Claude continues the previous conversation, remembering what it did before.
4. Takopi streams Claude's response back to Telegram.

The session ID is managed by Takopi internally — you never see or need it.

### When to start a fresh session

Send `/new` in the Telegram chat. This clears the stored session, and the next message starts a clean Claude conversation with no prior context.

Use `/new` when:
- Claude seems confused or stuck in a loop
- You are switching to a completely unrelated task
- The conversation has grown very long and responses are slow or expensive

### Other useful commands

| Command | What it does |
|---------|-------------|
| `/new` | Clear the session and start fresh |
| `/cancel` | Reply to a progress message to stop the current run |
| `/obsidian <message>` | Explicitly target the obsidian project |
| `/claude <message>` | Explicitly target the Claude engine |

### Things to keep in mind

- **Context accumulates.** Every message adds to the conversation history. After many messages (50+), Claude's context window fills up, responses slow down, and token costs increase. Use `/new` periodically.
- **`CLAUDE.md` is read once** at the start of each session. If you update `CLAUDE.md`, send `/new` to make Claude pick up the changes.
- **One request at a time.** Takopi serializes requests per session — if you send two messages quickly, the second waits until the first finishes.

## Typical operations

### Follow logs

```bash
docker compose logs -f takopi
docker compose logs -f obsidian-headless
```

Or both at once:

```bash
make logs
```

### Check the generated Takopi config

```bash
docker compose exec takopi sh -lc 'cat /state/.takopi/takopi.toml'
```

### Test Obsidian sync status

```bash
docker compose exec obsidian-headless ob sync-status --path /vault
```

## Health checks

The `takopi` service has a Docker healthcheck that monitors whether the Takopi process is running. If the process dies or hangs, Docker marks the container as unhealthy and `restart: unless-stopped` handles the restart.

You can check health status with:

```bash
docker inspect --format='{{.State.Health.Status}}' takopi
```

## Vault isolation

`90 Archive/` is hidden from the `takopi` container at the Docker level. A tmpfs is mounted over `/vault/90 Archive` with `mode=0000`, so Claude physically cannot read, list, or write anything there — even if it ignores the `CLAUDE.md` rules.

Obsidian Headless still sees the full vault and syncs `90 Archive/` normally.

To hide additional folders from the agent, add more entries under `tmpfs:` in `docker-compose.yml`:

```yaml
tmpfs:
  - "/vault/90 Archive:size=1k,mode=0000"
  - "/vault/Some Other Folder:size=1k,mode=0000"
```

## Recommended hardening and operational notes

- **Never set `CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS=true` unless you fully understand the risks.** In this mode Claude can execute any command without confirmation. The containers run as root, so a careless allowed-tools list can cause damage beyond the vault.
- Keep the allowed Claude tool set narrow.
- Put the vault under git if you want an easy audit trail of agent edits.
- Do not let the bot edit `.obsidian/` by default.
- Start with the PARA folders defined in `CLAUDE.md`.
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
- Claude Code install, settings path, and authentication / permissions model

See these upstream docs when you adapt the stack:
- Takopi: https://takopi.dev/
- Obsidian Headless / Sync: https://help.obsidian.md/
- Claude Code: https://docs.anthropic.com/en/docs/claude-code

# Takopi + Claude Code on Homelab via Coolify

Self-hosted Telegram-controlled coding agent. Deploys [Takopi](https://github.com/banteg/takopi) with [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (model: `claude-opus-4-6`) on your homelab.

No inbound HTTP required (no Traefik needed). The stack only talks outbound to Telegram, GitHub, and Anthropic API.

## Quick Start

### 1. Deploy in Coolify (Docker Compose build pack)

1. Create a new application from this Git repo
2. Build pack: **Docker Compose**
3. Set required environment variables (see below)
4. Deploy

### 2. Environment Variables

Copy `.env.example` to `.env` and fill in the values:

**Required:**

| Variable | Description |
|----------|-------------|
| `ANTHROPIC_API_KEY` | Anthropic API key for Claude Code |
| `TAKOPI_TELEGRAM_BOT_TOKEN` | Telegram bot token from @BotFather |
| `TAKOPI_TELEGRAM_CHAT_ID` | Telegram chat ID for the bot |
| `GH_TOKEN` | GitHub personal access token (`repo` + `workflow` scopes) |

**Optional:**

| Variable | Default | Description |
|----------|---------|-------------|
| `TAKOPI_ALLOWED_USER_IDS` | _(empty)_ | Comma-separated Telegram user IDs allowed to interact |
| `GITHUB_REPOS` | _(empty)_ | Auto-clone repos on startup: `owner/repo:alias,owner/repo2` |
| `AUTO_SETUP_REPOS` | `true` | Auto-detect and install dependencies after cloning |
| `CLAUDE_CODE_TASK_LIST_ID` | `takopi-homelab` | Shared task list ID for persistent cross-session task tracking |
| `OPENAI_API_KEY` | _(empty)_ | OpenAI API key for voice transcription (or local Whisper) |
| `VOICE_TRANSCRIPTION` | `false` | Enable voice message transcription |
| `VOICE_TRANSCRIPTION_MODEL` | `gpt-4o-mini-transcribe` | STT model name |
| `VOICE_TRANSCRIPTION_BASE_URL` | _(empty)_ | Custom base URL for local Whisper server |
| `VOICE_TRANSCRIPTION_API_KEY` | _(empty)_ | API key override for local Whisper server |
| `TAKOPI_CLAUDE_MODEL` | `claude-opus-4-6` | Claude model to use |
| `TAKOPI_CLAUDE_ALLOWED_TOOLS` | `Bash,Read,Edit,Write` | Tools available to Claude |
| `TAKOPI_CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS` | `false` | Skip permission prompts (dangerous!) |
| `TAKOPI_CLAUDE_USE_API_BILLING` | `true` | Use API billing vs Pro subscription |
| `TAKOPI_SESSION_MODE` | `chat` | Session mode: `chat` or `oneshot` |
| `TAKOPI_SHOW_RESUME_LINE` | `true` | Show resume line in Telegram |
| `TAKOPI_DEFAULT_ENGINE` | `claude` | Default engine |

### 3. Auto-cloning Repos

Set `GITHUB_REPOS` to automatically clone and register projects on startup:

```
GITHUB_REPOS=myorg/backend:back,myorg/frontend:front
```

Format: `owner/repo:alias` (alias is optional; defaults to repo name). Existing repos are pulled (`--ff-only`) instead of re-cloned.

### 4. Auto-setup (Dependency Installation)

When `AUTO_SETUP_REPOS=true` (default), the entrypoint automatically detects the project type and installs dependencies after cloning:

| Detected file | Action |
|---------------|--------|
| `.takopi-setup.sh` | Runs the custom script (highest priority) |
| `package-lock.json` | `npm ci` |
| `yarn.lock` | `yarn install --frozen-lockfile` |
| `pnpm-lock.yaml` | `pnpm install --frozen-lockfile` |
| `package.json` (no lockfile) | `npm install` |
| `pyproject.toml` | `uv sync` |
| `requirements.txt` | `uv pip install -r requirements.txt` |
| `go.mod` | `go mod download` |
| `Cargo.toml` | `cargo fetch` |

To use a custom setup script, create `.takopi-setup.sh` in your repo root:

```bash
#!/bin/bash
npm ci
npx prisma generate
cp .env.example .env
```

Set `AUTO_SETUP_REPOS=false` to disable auto-setup entirely.

### 5. Persistent Task Tracking

Claude Code's built-in Tasks system is enabled by default. Tasks persist across sessions on disk (`~/.claude/tasks/`), so the agent remembers what it was working on even after restarts.

**How it works:**
- The agent checks `TaskList` at the start of every session for unfinished work
- Complex requests are automatically broken into subtasks with dependency tracking
- Tasks support `blockedBy` relationships — the agent won't start blocked tasks until prerequisites are done
- All task state survives container restarts (stored in the `claude_state` volume)

**Shared task lists:** Multiple Claude Code sessions can share the same task list via `CLAUDE_CODE_TASK_LIST_ID`. By default it's set to `takopi-homelab`, but you can set a custom value per project or team.

**Example flow:**
1. You send: `/back implement user auth with JWT`
2. Agent creates tasks: "add JWT dependency", "create auth middleware", "add login endpoint", "add tests"
3. Agent works through tasks, marking each as completed
4. If session is interrupted, next session picks up where it left off

### 6. Voice Messages

Send voice messages in Telegram instead of typing. Takopi transcribes them and processes as text.

**Option A: OpenAI API (cloud)**

```
OPENAI_API_KEY=sk-...
VOICE_TRANSCRIPTION=true
```

Uses `gpt-4o-mini-transcribe` by default — fast and cheap (~$0.01/min).

**Option B: Local Whisper server (self-hosted)**

If you run a local [whisper.cpp](https://github.com/ggerganov/whisper.cpp) or [faster-whisper-server](https://github.com/fedirz/faster-whisper-server) on your homelab:

```
VOICE_TRANSCRIPTION=true
VOICE_TRANSCRIPTION_BASE_URL=http://whisper-server:8000/v1
VOICE_TRANSCRIPTION_API_KEY=local
VOICE_TRANSCRIPTION_MODEL=whisper-1
```

No OpenAI key needed — all processing stays on your hardware.

### 7. Agent Rules (CLAUDE.md)

The `templates/CLAUDE.md` file is automatically deployed to each cloned repo that doesn't already have a `CLAUDE.md`. This file instructs the Claude Code agent on how to work autonomously:

- PR-first workflow (never push to main)
- Codebase exploration strategy
- Test and lint before committing
- Error handling and recovery
- Safety constraints

**Per-repo customization:** If a repo already has its own `CLAUDE.md`, it is preserved and the template is not overwritten. This lets you tailor agent behavior per project.

## Usage from Telegram

```
/back fix the login bug in auth.py
/front add dark mode toggle to settings
```

Or with explicit engine:

```
/claude /back refactor the database layer
```

## Architecture

```
┌─────────────┐     ┌──────────────┐     ┌───────────────┐
│  Telegram    │◄───►│   Takopi     │────►│  Claude Code  │
│  (you)       │     │  (agent)     │     │  CLI          │
└─────────────┘     └──────┬───────┘     └───────┬───────┘
                           │                     │
                    ┌──────┴───────┐     ┌───────┴───────┐
                    │  GitHub      │     │  Anthropic    │
                    │  (repos/PRs) │     │  API          │
                    └──────────────┘     └───────────────┘
```

## File Structure

```
.
├── Dockerfile              # Ubuntu 24.04 + uv + takopi + Claude Code
├── docker-compose.yml      # Service definition with resource limits
├── entrypoint.sh           # Bootstrap: config, git auth, repo clone, auto-setup, start
├── templates/
│   └── CLAUDE.md           # Agent rules template (auto-deployed into repos)
├── .env.example            # Environment variable template
├── .dockerignore           # Build context exclusions
└── .gitignore
```

## Volumes

| Volume | Mount | Purpose |
|--------|-------|---------|
| `takopi_state` | `/home/agent/.takopi` | Takopi config and session state |
| `claude_state` | `/home/agent/.claude` | Claude Code tasks, settings, and session data |
| `repos` | `/work/repos` | Cloned repositories |

## Updating

### Update Takopi version

Change `TAKOPI_VERSION` in the `Dockerfile` and redeploy:

```dockerfile
ARG TAKOPI_VERSION=0.22.1
```

### Update configuration

Environment variable changes take effect on the next container restart -- the config is regenerated from env vars on every start.

### Full rebuild

```bash
docker compose build --no-cache
docker compose up -d
```

### Reset state

To start fresh (removes config and cloned repos):

```bash
docker compose down -v
docker compose up -d
```

## Resource Limits

Default limits in `docker-compose.yml`:

- **Memory:** 4 GB (reservation: 1 GB)
- **CPU:** 4 cores (reservation: 1.0)

Adjust in `docker-compose.yml` under `deploy.resources` if needed.

## Troubleshooting

**Bot doesn't respond in Telegram:**
- Check that `TAKOPI_TELEGRAM_BOT_TOKEN` and `TAKOPI_TELEGRAM_CHAT_ID` are correct
- Verify `TAKOPI_ALLOWED_USER_IDS` includes your Telegram user ID (or leave empty to allow all)
- Check container logs: `docker compose logs -f takopi`

**Repos not cloning:**
- Verify `GH_TOKEN` has `repo` scope
- Check the format: `owner/repo:alias`
- Look for `WARNING` lines in container logs

**Auto-setup fails:**
- Check that required toolchains are available in the container (Node.js, Go, Rust need to be added to the Dockerfile if needed)
- Use a custom `.takopi-setup.sh` script for non-standard setups
- Set `AUTO_SETUP_REPOS=false` to skip auto-setup and let the agent handle it

**Claude errors:**
- Verify `ANTHROPIC_API_KEY` is valid and has billing set up
- Check model name is correct in `TAKOPI_CLAUDE_MODEL`

## Security Notes

- GH_TOKEN is stored in an agent-owned file (`chmod 600`) at `/home/agent/.gitconfig`
- Never set `TAKOPI_CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS=true` unless you fully trust the environment
- The `CLAUDE.md` template enforces PR-first workflow to prevent direct pushes to main
- Git user identity is set to `takopi-agent` to clearly identify agent commits

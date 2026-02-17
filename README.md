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
├── entrypoint.sh           # Bootstrap: config, git auth, repo clone, start
├── templates/
│   └── CLAUDE.md           # Agent rules template (copied into repos)
├── .env.example            # Environment variable template
├── .dockerignore           # Build context exclusions
└── .gitignore
```

## Volumes

| Volume | Mount | Purpose |
|--------|-------|---------|
| `takopi_state` | `/home/agent/.takopi` | Takopi config and session state |
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

**Claude errors:**
- Verify `ANTHROPIC_API_KEY` is valid and has billing set up
- Check model name is correct in `TAKOPI_CLAUDE_MODEL`

## Security Notes

- GH_TOKEN is stored in a root-only file (`chmod 600`) inside the container
- Never set `TAKOPI_CLAUDE_DANGEROUSLY_SKIP_PERMISSIONS=true` unless you fully trust the environment
- The `CLAUDE.md` template enforces PR-first workflow to prevent direct pushes to main

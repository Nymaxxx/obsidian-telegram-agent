# Configuration

← Back to [README](../README.md)

All configuration is done through environment variables in `.env`. See [`.env.example`](../.env.example) for the full list with descriptions.

## Repository layout

```text
.
├─ .github/
│  ├─ ISSUE_TEMPLATE/         ← bug report / feature request templates
│  └─ workflows/
│     ├─ ci.yml               ← shellcheck, hadolint, actionlint, compose validate
│     └─ deploy.yml           ← auto-deploy on push to main
├─ docker-compose.yml
├─ .env.example
├─ Makefile
├─ CHANGELOG.md
├─ docs/                      ← long-form docs (you are here)
├─ scripts/
│  ├─ bootstrap.sh            ← one-line VPS install entry (curl | bash)
│  ├─ install.sh              ← interactive setup wizard (run via `make setup`)
│  └─ auth-obsidian.sh        ← Obsidian Sync login / sync / status helper
├─ takopi/
│  ├─ Dockerfile
│  └─ entrypoint.sh           ← generates takopi.toml + ~/.claude/settings.json
├─ obsidian-headless/
│  ├─ Dockerfile
│  └─ entrypoint.sh
└─ vault/
   ├─ CLAUDE.base.md          ← agent instructions, project default (tracked in git)
   ├─ CLAUDE.local.md         ← your personal overrides (created by install.sh, gitignored)
   ├─ CLAUDE.md               ← generated on each container start (do not edit)
   ├─ .trash/                 ← soft-delete destination (the agent has no `rm`)
   └─ templates/
      └─ note.md              ← template for new notes
```

## Agent behavior

The agent reads `vault/CLAUDE.md` at the start of every session. That file is **regenerated on every takopi container start** by [`takopi/entrypoint.sh`](../takopi/entrypoint.sh) from three layers, concatenated in this order:

| # | Source | Tracked in git? | Edited by |
|---|--------|----------------|-----------|
| 1 | [`vault/CLAUDE.base.md`](../vault/CLAUDE.base.md) | yes | maintainers, via PR / `git pull` |
| 2 | `vault/CLAUDE.local.md` | no | you, on the VPS |
| 3 | `CLAUDE_EXTRA_INSTRUCTIONS` env var | no | `.env`, GitHub Actions Variable, or Secret |

Later sections override earlier ones — if you write a personal rule that contradicts the base, your rule wins because Claude reads it later.

> **Do not edit `vault/CLAUDE.md` directly.** Anything you put there will be wiped on the next container restart. Edit one of the three sources instead.

### When to use which layer

- **`CLAUDE.base.md`** — universal safety rules and reasonable defaults that everyone benefits from (deny-list interactions, soft-delete via `.trash/`, message-handling templates, editing style). If your change should ship to everyone, propose a PR against this file.
- **`CLAUDE.local.md`** — anything specific to *your* vault: real folder names instead of the PARA defaults, the language you write notes in, personal style preferences, additional off-limits paths. `install.sh` seeds this from [`templates/CLAUDE.local.md.example`](../templates/CLAUDE.local.md.example) on first run; edit it freely. The file is in `.gitignore`, so deploys never touch it.
- **`CLAUDE_EXTRA_INSTRUCTIONS`** — optional, useful when you want all configuration centralized and never want to SSH into the VPS to edit a file. Set it as a [**GitHub Actions Variable**](https://docs.github.com/en/actions/learn-github-actions/variables) (Settings → Secrets and variables → Actions → **Variables** tab) — these are visible in plain text in the UI, easy to inspect and edit, and not masked in logs. Use a Secret instead only if your rules really are sensitive. The [deploy workflow](../.github/workflows/deploy.yml) reads `vars.CLAUDE_EXTRA_INSTRUCTIONS` first and falls back to `secrets.CLAUDE_EXTRA_INSTRUCTIONS`, then writes the value into `.env` on the VPS as a quoted multi-line string. Multi-line content is preserved verbatim.

After changing any layer, send `/new` in Telegram (or `docker compose restart takopi` on the VPS) to start a fresh Claude session that picks up the regenerated `CLAUDE.md`.

## Choosing a model

The default in this stack is `claude-haiku-4-5` — fast and cheap, suitable for most vault tasks (capturing notes, moving files, summarizing). Switch to `claude-sonnet-4-6` via `CLAUDE_MODEL=claude-sonnet-4-6` in `.env` when you need complex reasoning or long-context rewrites (~20x more expensive).

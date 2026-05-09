# Auto-deploy with GitHub Actions

← Back to [README](../README.md)

Four workflows live in [`.github/workflows/`](../.github/workflows/):

- [`ci.yml`](../.github/workflows/ci.yml) runs on every PR and push: shellcheck on shell scripts, hadolint on the Dockerfiles, actionlint on the workflows themselves, and `docker compose config -q` to validate the compose file. Lint-only, no image build, ~30 seconds.
- [`deploy.yml`](../.github/workflows/deploy.yml) runs on pushes to `main` (and via manual dispatch). It SSHs into the VPS, syncs code, writes `.env` from GitHub Secrets, runs `docker compose pull && docker compose up -d`, and prunes dangling images. Telegram notifications are sent on success and failure.
- [`build-images.yml`](../.github/workflows/build-images.yml) runs when `takopi/**` or `obsidian-headless/**` changes on `main` (or on Release publish). It builds and pushes multi-arch (amd64+arm64) images to GHCR with tags `latest`, `<short-sha>`, and (for releases) `v<X.Y.Z>`.
- [`inspect.yml`](../.github/workflows/inspect.yml) is a manual-dispatch diagnostic workflow. SSHes to the VPS and prints the deployed commit, sanitized `.env` contents, container status, sizes of the `CLAUDE.{base,local,md}` layers, the assembled `vault/CLAUDE.md` as the agent sees it, the takopi container's resolved `CLAUDE_EXTRA_INSTRUCTIONS`, and recent entrypoint output. Run it from **Actions → Inspect VPS → Run workflow** when the agent's behavior doesn't match expectations.

## Required GitHub Secrets

| Secret | Description |
|---|---|
| `VPS_HOST` | IP address or hostname of your VPS |
| `VPS_USER` | SSH username (e.g. `deploy`) |
| `VPS_SSH_KEY` | SSH private key (full contents of `~/.ssh/id_ed25519`) |
| `TELEGRAM_BOT_TOKEN` | Telegram bot token |
| `TELEGRAM_CHAT_ID` | Chat ID where the bot listens |
| `ANTHROPIC_API_KEY` | Anthropic API key |

Optional secrets mirror the `.env` variables — see [`.env.example`](../.env.example) for the full list.

`CLAUDE_EXTRA_INSTRUCTIONS` (additional rules for the agent — not actually a secret) can be set as either a **GitHub Actions Variable** (Settings → Secrets and variables → Actions → **Variables** tab) or a Secret. Variables are preferred: they're visible in plain text in the UI, easy to inspect and edit, and not masked in logs. The deploy workflow reads `vars.CLAUDE_EXTRA_INSTRUCTIONS` first and falls back to `secrets.CLAUDE_EXTRA_INSTRUCTIONS`.

To trigger a deploy without a code push: **Actions > Deploy > Run workflow**.

## What persists between deploys

| Path | Contents |
|---|---|
| `./vault/` | Obsidian notes — gitignored, untouched by deploy |
| `./takopi-state/` | Takopi session data — gitignored |
| `./obsidian-state/` | Obsidian Sync auth — gitignored |

## Setting up SSH access for CI

Generate a dedicated key for GitHub Actions on your local machine:

```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/obsidian-deploy -N ""
```

Add the public key to the VPS:

```bash
ssh root@<VPS_IP> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
  echo '$(cat ~/.ssh/obsidian-deploy.pub)' >> ~/.ssh/authorized_keys && \
  chmod 600 ~/.ssh/authorized_keys"
```

Copy the contents of `~/.ssh/obsidian-deploy` (the private key, including BEGIN/END lines) into the `VPS_SSH_KEY` secret on GitHub.

Once secrets are set, trigger a manual deploy via **Actions > Deploy > Run workflow** to verify the connection. Subsequent pushes to `main` will deploy automatically.

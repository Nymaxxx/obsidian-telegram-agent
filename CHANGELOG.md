# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Customizable `CLAUDE.md` via three layers.** `vault/CLAUDE.md` is now
  generated on every takopi container start by concatenating
  `vault/CLAUDE.base.md` (universal safety + tool rules + a generic
  message-handling template, tracked in git) +
  `vault/CLAUDE.local.md` (per-install layout, capture rules, frontmatter
  convention, language preferences — gitignored, seeded from
  `templates/CLAUDE.local.md.example` by `scripts/install.sh`) + the optional
  `CLAUDE_EXTRA_INSTRUCTIONS` env var. Later sections win on conflict, so
  personal rules in `CLAUDE.local.md` override the base. The deploy workflow
  passes `CLAUDE_EXTRA_INSTRUCTIONS` through as a multi-line-safe env var, so
  CI-only setups can keep all configuration in GitHub Actions Variables
  (preferred — visible in the UI, not masked in logs) or Secrets, without
  SSH'ing to the VPS. Deploy reads `vars.CLAUDE_EXTRA_INSTRUCTIONS` with
  fallback to `secrets.CLAUDE_EXTRA_INSTRUCTIONS`. `CLAUDE.base.md` deliberately ships *no* opinion on
  folder layout (PARA / Zettelkasten / flat — your call); the template shows
  three example structures to copy from. See
  [Agent behavior](docs/configuration.md#agent-behavior) for the full picture.
- **Migration for existing installs.** Run on the VPS:
  ```bash
  cd ~/obsidian-telegram-agent
  cp vault/CLAUDE.md vault/CLAUDE.local.md   # save your personalised rules
  git pull                                   # pulls CLAUDE.base.md, drops vault/CLAUDE.md from git
  docker compose up -d takopi                # entrypoint regenerates vault/CLAUDE.md
  ```
- **One-line VPS install via `scripts/bootstrap.sh`.** A single
  `curl ... | bash` command installs Docker, clones the repo, runs the
  wizard, and starts the stack. Supports both interactive and
  non-interactive (cloud-init / CI) modes via env vars. New README
  section "One-line install".
- **Pre-built multi-arch Docker images on GHCR.** New
  `.github/workflows/build-images.yml` builds and pushes
  `linux/amd64` + `linux/arm64` images for both services on every push
  to `main` and on Release publish. Cuts VPS install time from
  ~5–10 min (local build) to ~30 seconds (image pull); also fixes OOM
  on 1 GB VPS. Tags: `latest`, `<short-sha>`, `v<X.Y.Z>`.
- **`docker-compose.dev.yml` override** for contributors who want to
  build locally. Keeps the production compose file lean and pins local
  builds to `:dev` tag so they can't collide with `:latest`.
- **`IMAGE_TAG` env var** in `.env.example` and `deploy.yml` for
  pinning the image version.
- **Auto-detect Telegram chat_id via `/claim` flow.** If
  `TELEGRAM_CHAT_ID` is unset, `takopi/entrypoint.sh` polls
  `getUpdates`, prints a one-time random claim token, and waits for
  the operator to send `/claim <token>` from the chat they want to
  bind. The detected chat_id is persisted to
  `takopi-state/.takopi/chat_id`. Reduces required secrets from 3 to
  2 (bot token + Anthropic key).
- **Non-interactive mode for `scripts/install.sh`** via
  `NONINTERACTIVE=1` (or `--non-interactive`). Reads required env
  vars instead of prompting. New helper `read_tty` makes the
  interactive path work under `curl-pipe-bash`.
- **`scripts/install.sh` `--help` flag** documents the available env
  vars and flags.
- **`make bootstrap`, `make setup-ci`, `make up-dev`, `make pull`** —
  Makefile shortcuts for the new flows.
- Prominent disclaimer in the README about the agent's destructive
  capabilities and the "use at your own risk" nature of the project.
- New `Backups` section with recommended strategies (git, restic/borg,
  filesystem snapshots) and a one-liner manual snapshot command.
- New `Cost controls` subsection explaining how to set Anthropic spend
  alerts and per-key spend limits. Takopi has no built-in rate limiter,
  so users are nudged to configure guard-rails at the API-key level.
- New `Concurrent writes` note in Backups: documents the (rare) race
  between Obsidian Sync and the agent writing the same file.
- New `Vault file ownership` tip: containers run as root, so vault
  files end up root-owned on the host; provides the `chown` recovery
  command.
- Security notes now cover prompt injection from URL content, secrets
  visible via `docker inspect`, and Obsidian Sync auth tokens stored
  in `obsidian-state/`.
- `.github/workflows/ci.yml`: minimal lint workflow running shellcheck,
  hadolint on both Dockerfiles, actionlint on workflows, and
  `docker compose config -q` on PRs and pushes to `main`.
- Docker resource limits: `mem_limit` (768m for takopi, 512m for
  obsidian-headless), matching `memswap_limit`, and per-service `cpus`.
- Log rotation via `logging.driver=json-file` (10 MB max, 3 files) on
  both containers, so docker logs no longer fill the disk over time.
- Mode-aware healthcheck on `obsidian-headless`: checks `pgrep -f 'ob sync'`
  when autostart is on, no-ops when the container is idling.
- The setup wizard now shows a destructive-access warning and requires
  explicit acknowledgement before continuing.
- Stronger guardrails in `vault/CLAUDE.md`: vague cleanup requests are
  no longer permission to delete, and bulk-destructive shell commands
  require explicit confirmation.
- TL;DR section and `make setup` shortcut in the README.
- Instructions for finding your Telegram chat ID.
- GitHub issue templates (bug report, feature request) and a Discussions link.
- Docker and "Powered by Claude" badges in the README header.
- `TAKOPI_SHOW_RESUME_LINE`, `TAKOPI_DEFAULT_ENGINE`, `TAKOPI_DEFAULT_PROJECT`,
  `TAKOPI_TOPICS_ENABLED`, and `TAKOPI_TOPICS_SCOPE` documented in
  `.env.example`.
- `CLAUDE_ALLOWED_TOOLS` and `CLAUDE_DENIED_COMMANDS` are now propagated
  by the GitHub Actions deploy workflow when set as secrets.
- README footer links to `CHANGELOG.md`, `CONTRIBUTING.md`, and the
  GitHub issue tracker.
- README "Typical operations" includes a one-liner to inspect the
  active deny list (`cat /state/.claude/settings.json`).
- Repository layout in the README updated to include `ci.yml`, the
  ISSUE_TEMPLATE folder, `install.sh`, `CHANGELOG.md`, and `vault/.trash/`.

### Changed
- **`docker-compose.yml` now uses `image:` (GHCR) by default** instead
  of `build:`. Local development uses the new `docker-compose.dev.yml`
  override.
- **`scripts/install.sh` and `.github/workflows/deploy.yml`** now
  `docker compose pull && docker compose up -d` instead of building
  locally. `make up` mirrors this.
- **`TELEGRAM_CHAT_ID` is now optional** in `.env.example` and the
  install wizard. The "How to find your chat ID" README section is
  reframed as a manual override under the new "Chat ID binding"
  heading.
- **README TL;DR leads with the one-line install** and points at both
  interactive and non-interactive forms. Quick start section retains
  step-by-step manual instructions.
- **Repo URL casing normalized** to `Nymaxxx/obsidian-telegram-agent`
  (was inconsistently lowercased as `nymaxxx/...` in places). The
  install directory stays `~/obsidian-telegram-agent`. Affects
  README, CONTRIBUTING, ISSUE_TEMPLATE config, and the bootstrap /
  GHCR image references.
- **Two-layer security model for the agent's command surface.** End-to-end
  testing showed that the previously-shipped narrow allowlist
  (`Bash(mv *)`, `Bash(git *)`) silently breaks `mv` in Takopi's
  non-interactive flow: Claude Code treats narrow Bash patterns as
  "needs interactive approval", and there's no TTY to approve them.
  Replaced with a permissive allowlist
  (`["Bash","Read","Edit","Write","Glob","Grep","LS","WebFetch"]`)
  plus a deny list shipped via `~/.claude/settings.json` that hard-blocks
  destructive commands (`rm`, `rmdir`, `chmod`, `chown`, `dd`, `mkfs`,
  `shred`, `sudo`). The deny list is the actual security boundary —
  enforced regardless of permission mode and resilient to evasion via
  `bash -c`, `find -delete`, etc. Verified empirically that `rm` is
  refused while `mv`, `WebFetch`, and ordinary file ops succeed.
- **New `CLAUDE_DENIED_COMMANDS` env var** lets users extend the deny
  list without forking the entrypoint. Defaults match the list above.
- **takopi/entrypoint.sh** now generates `~/.claude/settings.json` on
  every container boot, in addition to `~/.takopi/takopi.toml`.
- **Soft-delete via `/vault/.trash/`** is the supported alternative to
  `rm` (which is blocked). The pre-existing `vault/.trash/` directory
  ships in the repo so the soft-delete path always exists. CLAUDE.md
  "Tool capabilities" table rewritten to reflect the actual setup
  (full Bash with destructive commands blocked at the system level).
- Claude Code CLI is now pinned to a specific version (`2.1.128`) in
  `takopi/Dockerfile` via the install script's positional version
  argument, so an upstream release can no longer change behavior in
  production without an explicit version bump.
- `takopi/entrypoint.sh` rewritten to use a single redirection block,
  eliminating the multi-`>>` heredoc pattern flagged by shellcheck.
  Defaults are now pre-resolved into shell variables before the heredoc
  so JSON-array defaults survive bash parameter expansion (the previous
  `${VAR:-["a","b"]}` form silently dropped the embedded quotes when
  the fallback path fired).
- `takopi` service no longer requests `stdin_open`/`tty` (it's
  non-interactive). `obsidian-headless` keeps them so `ob login` still
  works via `docker compose exec`.
- The deploy workflow now runs `docker image prune -f` after a
  successful build, keeping the VPS disk bounded.
- Deploy workflow propagates `CLAUDE_ALLOWED_TOOLS` from secrets when
  set.
- `CLAUDE_USE_API_BILLING` now defaults to `true` everywhere (`.env.example`,
  `docker-compose.yml`, Takopi entrypoint), matching the API-key-based setup
  this project recommends.
- README section order now matches the table of contents.

### Removed
- Dead `watch_config = true` line from the generated Takopi config —
  it was a no-op because the entrypoint regenerates the file on every
  boot.

### Fixed
- `scripts/auth-obsidian.sh` is now executable so the Obsidian Sync setup
  commands in the README work as written.
- Replaced `YOUR_USERNAME` placeholders in `README.md` and `CONTRIBUTING.md`
  with the actual repository path.
- **`scripts/install.sh` now persists every documented optional env
  var** to `.env` (`IMAGE_TAG`, `TAKOPI_SHOW_RESUME_LINE`,
  `TAKOPI_TOPICS_*`, `VOICE_TRANSCRIPTION_MODEL/_BASE_URL/_API_KEY`,
  `CLAUDE_ALLOWED_TOOLS`, `CLAUDE_DENIED_COMMANDS`, …). Previously a
  caller could pass e.g. `IMAGE_TAG=v0.3.0` for the first deploy but
  the value silently dropped on the next `docker compose` invocation
  because the wizard never wrote it to `.env`.
- **`scripts/bootstrap.sh` always prints the commit SHA** after clone
  or pull, and prints a multi-line banner when `git pull --ff-only`
  fails so a stale-checkout deploy is no longer silent.
- **`takopi/entrypoint.sh` validates `CLAUDE_ALLOWED_TOOLS` and
  `CLAUDE_DENIED_COMMANDS`** as JSON arrays before writing
  `~/.claude/settings.json`, so a typo in the operator's `.env` now
  fails fast with a clear error instead of putting the container into
  a restart loop on cryptic JSON parse errors.
- **`takopi/entrypoint.sh` chat-id loader requires a non-empty file**
  (`-s` instead of `-f`) and self-heals an empty `chat_id` left over
  from a container killed mid-write.
- **Healthcheck for `takopi` matches the binary path
  (`/root/.local/bin/takopi`)** instead of the substring `takopi`, so
  the entrypoint script itself can't false-positive while the /claim
  flow is waiting.

### Changed
- **Default deny list extended** with `Bash(find * -delete)`,
  `Bash(find * -exec rm *)`, and `Bash(truncate *)` to cover the most
  common bulk-deletion shortcuts that pattern-matching on `rm` alone
  would miss. README and `vault/CLAUDE.md` now describe the deny list
  as a guard rail rather than a complete sandbox, and explicitly call
  out that scripted-language evasions (`python -c '...os.remove...'`)
  remain in scope — backups stay mandatory. Supersedes the earlier
  "resilient to evasion via `bash -c`, `find -delete`" claim, which
  was true only for the literal patterns enumerated in the list.
- **README "Choosing a model" now states explicitly that the default
  is Sonnet**, removing the implicit-Haiku-recommendation that
  conflicted with the actual defaults in `.env.example`,
  `docker-compose.yml`, `install.sh`, and `deploy.yml`.
- **README repo layout** now lists `scripts/bootstrap.sh`, and
  `auth-obsidian.sh`'s `status`, `sync`, and `continuous` subcommands
  are documented (Quick start step 4 + Typical operations).

## [0.1.0] - 2026-04

Initial public release.

- Telegram bridge to Claude Code via [Takopi](https://takopi.dev/).
- Headless Obsidian Sync container.
- PARA-style vault scaffold with `CLAUDE.md` agent rules and a note template.
- Docker Compose stack with vault tmpfs isolation for off-limits folders.
- Optional voice-note transcription via Whisper.
- Interactive setup wizard (`scripts/install.sh`).
- One-step Obsidian Sync helper (`scripts/auth-obsidian.sh`).
- GitHub Actions deploy workflow with Telegram notifications.

---
title: "Audit and improvement plan — Obsidian Telegram Agent"
description: "July 2026 audit of the codebase and docs, ecosystem review (Takopi, Obsidian, transcription, competitors, Claude Agent SDK), and a staged improvement plan."
---

# Audit and improvement plan (July 2026)

A point-in-time audit of the project (v0.3.0) plus a review of what appeared in the ecosystem through mid-2026, distilled into a staged, checkbox-driven plan. Each item is scoped so it can be picked up independently in a future session or PR.

- [Audit findings](#audit-findings)
- [Ecosystem review](#ecosystem-review-july-2026)
- [Improvement plan](#improvement-plan)
  - [Stage 1 — audit fixes](#stage-1--audit-fixes-fast-low-risk)
  - [Stage 2 — cheap upgrades from the ecosystem review](#stage-2--cheap-upgrades-from-the-ecosystem-review)
  - [Stage 3 — new capabilities](#stage-3--new-capabilities)
- [Takopi strategy](#takopi-strategy)

## Audit findings

### Critical

1. **CI race: deploy vs. image build.** `deploy.yml` and `build-images.yml` both trigger on `push` to `main`. A commit touching `takopi/**` starts them in parallel; the deploy job runs `docker compose pull` on the mutable `:latest` tag while the build job is still rebuilding it — so the VPS deploys the *previous* image, and the new one only lands on the next deploy. There is no `workflow_run`/`needs:` chain between the two workflows.
2. **Secrets in plaintext on a persistent volume.** `takopi/entrypoint.sh` renders `bot_token` and `voice_transcription_api_key` into `~/.takopi/takopi.toml` (lines 188 and 201–203), which lives on the `./takopi-state` host volume. Any backup of the project directory captures them. `docs/security.md` mentions `docker inspect` and `obsidian-state/` but not this file.
3. **Deny-list bypasses that use plain shell syntax.** `docs/security.md` and `CLAUDE.base.md` acknowledge the `python -c os.remove` class of bypass, but simpler holes exist with `Bash` allowed: `> note.md` truncates a file and matches no pattern, `mv` over an existing file clobbers it (and `mv` is allowlisted), `git rm` / `git reset --hard` / `git clean` are only guarded by a soft instruction, `tee` overwrites, and the prefix-style patterns (`Bash(rm *)`) don't match `/bin/rm`. Users can currently overestimate the strength of this guard-rail.

### Reliability

4. **Blocking `/claim` loop keeps the container unhealthy indefinitely.** `detect_chat_id` polls `getUpdates` in a `while true` loop until a chat binds; the takopi binary hasn't started yet, so the `pgrep -f /root/.local/bin/takopi` healthcheck fails after `start_period`. Cosmetic (no autoheal configured) but misleading, and there is no timeout.
5. **`OBSIDIAN_AUTOSTART_SYNC=true` with sync not yet configured** sends the container into `sleep infinity` while the mode-aware healthcheck expects an `ob sync` process — permanently unhealthy. Documented in `docs/operations.md`, but the healthcheck can't distinguish "not configured" from "crashed".

### Documentation drift

6. **CHANGELOG contradicts the code on the default model.** An entry under `[0.3.0]` claims the README "now states explicitly that the default is Sonnet", but the actual default everywhere (`docker-compose.yml`, `.env.example`, `install.sh`, `deploy.yml`, `docs/configuration.md`) is `claude-haiku-4-5`.
7. **Duplicate `### Changed` heading** inside the `[0.3.0]` section of `CHANGELOG.md` — Keep a Changelog expects one section per category per release.
8. **Repo layout in `docs/configuration.md` is stale**: it lists two workflows under `.github/workflows/`, but there are four (`ci.yml`, `deploy.yml`, `build-images.yml`, `inspect.yml`); `docs/auto-deploy.md` already says "four workflows". The layout also omits `docker-compose.dev.yml`, `CONTRIBUTING.md`, `LICENSE`.
9. **Broken README link**: the "Tailor the agent" section links to `vault/CLAUDE.local.md`, which is gitignored and absent from the repo — a 404 on GitHub. Should point at `templates/CLAUDE.local.md.example`.
10. Minor: README says bootstrap is "~120 lines" (actual: 143); `LICENSE` says 2025 while releases are dated 2026.

### DX / CI gaps

11. **No tests at all** — CI is lint-only (shellcheck/hadolint/actionlint/`compose config`), while `install.sh` and `entrypoint.sh` carry non-trivial logic (JSON validation, CRLF handling, three-layer `CLAUDE.md` assembly, `ob` output parsing).
12. **Supply-chain hygiene**: third-party actions pinned by tag rather than commit SHA (`appleboy/ssh-action@v1`, etc.); `ci.yml` installs actionlint via an unpinned `curl | bash`; base images (`python:3.13-slim`, `node:22-alpine`) not pinned by digest; no `dependabot.yml`; no `SECURITY.md` disclosure policy.

### What is already good (keep as-is)

- App versions pinned with an explicit "bump deliberately" rationale (takopi, Claude Code, obsidian-headless).
- Honest two-layer permission model: permissive allowlist, deny-list as the real boundary, documented as such.
- Fail-fast JSON validation of `CLAUDE_ALLOWED_TOOLS` / `CLAUDE_DENIED_COMMANDS` before writing `settings.json` — prevents restart loops.
- The `/claim` chat-binding flow as a defense against bot-token leaks.
- Resource limits with `memswap_limit == mem_limit`, log rotation on both services, mode-aware healthcheck with correct `$${VAR}` escaping.
- Script hygiene throughout: `set -euo pipefail`, CRLF normalization for Windows SSH, injection-safe exec, idempotent bootstrap.
- `.gitattributes` forcing LF on shell/Dockerfile/YAML; proper CHANGELOG, CONTRIBUTING, issue templates.

## Ecosystem review (July 2026)

**Takopi is dormant.** Last release v0.23.4 (May 25, 2026); no commits since, 27 open PRs accumulating. It works fine today, but it's a dependency risk. Maintained alternatives if that ever matters: [RichardAtCT/claude-code-telegram](https://github.com/RichardAtCT/claude-code-telegram) (~2.7k stars, built on the Claude Agent SDK, has a cron scheduler, webhooks, file uploads), the official **Claude Code Channels** Telegram plugin (first-party, but requires a permanently-running interactive session), and [Happy](https://github.com/slopus/happy) (mobile client rather than a Telegram bridge). See [Takopi strategy](#takopi-strategy).

**obsidian-headless moved fast.** This repo pins 0.0.8; upstream is at 0.0.13 (July 2026) with active iteration (Publish operations, remote vault creation).

**Voice transcription got much cheaper.** Groq's `whisper-large-v3-turbo` costs ~$0.04/hour (vs. ~$0.18/hour for `gpt-4o-mini-transcribe`), has a free tier that comfortably covers personal-bot volume, and accepts Telegram's ogg/opus natively. Takopi already supports a custom `voice_transcription_base_url`, so this is a config-and-docs change, not code. For a fully local option on 1–2 vCPU, GigaAM v3 (Russian, ~3% WER, ONNX INT8, ~250 MB) plus whisper.cpp base for English is feasible but requires running a separate OpenAI-compatible service.

**Obsidian shipped Bases and changed frontmatter rules.** `.base` files are plain YAML the agent can create and edit programmatically. Since 1.9, singular `tag`/`alias`/`cssclass` frontmatter keys are removed — agents must write plural `tags`/`aliases`/`cssclasses`. The official Obsidian CLI (1.12) remote-controls the desktop app and is not usable headless. MCP servers for Obsidian exist, but direct filesystem access (what this project already does) covers the vast majority of use cases.

**The personal-agent category exploded.** OpenClaw (~380k stars), nanoclaw (~30k), and close analogues like agent-second-brain (Telegram → Claude Code → Obsidian) converged on a common feature set worth borrowing: a periodic **heartbeat** turn ("check inbox/calendar, message me only if actionable"), a **morning digest**, natural-language **self-scheduling** ("remind me Thursday" → the agent writes its own cron entry), a nightly **inbox auto-filing** pass (tags, wikilinks, task extraction), and **structured memory files in the vault** (`USER.md`, `memory/YYYY-MM-DD.md`, periodic consolidation). Notably, OpenClaw's widely-reported security incidents make this project's sandboxed, deny-listed, single-chat design a genuine differentiator — worth preserving while adopting the features.

**Claude platform.** The default `claude-haiku-4-5` ($1/$5 per MTok) remains the right budget choice; Sonnet 5 launched with intro pricing ($2/$10 until Aug 31, 2026). The **Claude Agent SDK** (`claude-agent-sdk` on PyPI / `@anthropic-ai/claude-agent-sdk` on npm) is now Anthropic's recommended way to embed Claude Code in a bot — it exposes the full harness (tools, sessions, hooks, subagents, MCP, streaming) as a library, which is the natural long-term replacement for shelling out to the CLI.

## Improvement plan

### Stage 1 — audit fixes (fast, low risk)

- [ ] **Fix the CI race**: make the push-triggered deploy run via `workflow_run` after `build-images.yml` succeeds (keep `workflow_dispatch` for manual deploys). Alternative: deploy by image digest instead of `:latest`.
- [ ] **Extend the deny-list** in `docker-compose.yml` and `.env.example`: `Bash(git rm *)`, `Bash(git reset --hard*)`, `Bash(git clean *)`, `Bash(/bin/rm *)`, `Bash(/usr/bin/rm *)`, `Bash(tee *)`. Document the bypasses that remain by construction (`> file` truncation, `mv` clobber) in `docs/security.md`, and state plainly that backups are the real boundary.
- [ ] **Document and harden secret storage**: add a `docs/security.md` section on `takopi-state/.takopi/takopi.toml` containing the bot token and API keys; `chmod 600` the rendered file in `takopi/entrypoint.sh`.
- [ ] **Fix documentation drift**: CHANGELOG duplicate `### Changed` and the incorrect Sonnet-default claim; full four-workflow repo layout in `docs/configuration.md`; README link → `templates/CLAUDE.local.md.example`; LICENSE year.
- [ ] **Bump pins**: obsidian-headless 0.0.8 → 0.0.13, takopi 0.22.3 → 0.23.4, Claude Code to current. Pin third-party GitHub Actions by commit SHA; replace the `curl | bash` actionlint install with a pinned release; add `.github/dependabot.yml` (docker + github-actions) and a `SECURITY.md`.
- [ ] **Add tests**: bats tests for the tricky functions in `install.sh` / `takopi/entrypoint.sh` (JSON validation, CRLF normalization, three-layer `CLAUDE.md` assembly) plus a CI job; validate the dev override with `docker compose -f docker-compose.yml -f docker-compose.dev.yml config`.

### Stage 2 — cheap upgrades from the ecosystem review

- [ ] **Recommend Groq for transcription**: document `VOICE_TRANSCRIPTION_BASE_URL=https://api.groq.com/openai/v1` + `VOICE_TRANSCRIPTION_MODEL=whisper-large-v3-turbo` in `.env.example` and `docs/configuration.md` (free tier, ~4× cheaper). Keep OpenAI as the default for compatibility.
- [ ] **Teach the agent about Bases and modern frontmatter**: add `.base` YAML basics and the plural-keys rule (`tags`/`aliases`/`cssclasses`) to `vault/CLAUDE.base.md`; extend the vault-operations taxonomy (weekly review, merge duplicates).
- [ ] **Refresh model guidance** in `docs/configuration.md`: Haiku 4.5 stays the default; mention Sonnet 5 intro pricing while it lasts.

### Stage 3 — new capabilities

- [ ] **Scheduled digest / nightly filing**: a lightweight cron mechanism (host cron or a small sidecar) that runs `claude -p` with a task file from `vault/schedules/*.md` — morning digest (yesterday's notes + open tasks → Telegram via Bot API) and a nightly Inbox pass (tags, wikilinks, filing). Partially covers the "safe slash-commands" roadmap item and matches the single most-loved feature of competing agents.
- [ ] **Structured memory in the vault**: `USER.md` and `memory/YYYY-MM-DD.md` templates plus CLAUDE.base.md instructions; memory consolidation as a nightly scheduled task once the scheduler exists.
- [ ] **Optional semantic search**: evaluate [tobi/qmd](https://github.com/tobi/qmd) (SQLite FTS5 + sqlite-vec, CPU-friendly) as an opt-in compose service for "what did I write about X?" queries beyond grep.

## Takopi strategy

Stay on Takopi short-term — it works, and a bridge migration is expensive — but treat it as dormant:

1. Bump the pin to the final release (0.23.4) and note the upstream status in `docs/configuration.md`.
2. Add a long-term roadmap item: migrate the bridge to the **Claude Agent SDK**. That removes the dormant dependency and unlocks programmatic hooks, subagents, streaming, and in-process MCP tools — the foundation Stage 3 features would otherwise have to bolt on from outside.

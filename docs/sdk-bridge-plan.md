---
title: "SDK bridge plan — Obsidian Telegram Agent"
description: "Design assessment and phased plan for replacing the dormant Takopi bridge with a purpose-built bridge on the Claude Agent SDK: comparison against real alternatives, what to build, what to reuse, risks."
---

# Own bridge on the Claude Agent SDK: assessment and plan

> **Status (July 2026): the decision to build has been made.** This document remains the assessment record (alternatives, code-size data, why the SDK changes the math). The living build specification — full feature set, Takopi parity checklist, env contract, phased plan — is in **[bridge-spec.md](bridge-spec.md)**.

Companion to the [improvement plan](improvement-plan.md), expanding strategic option [D1.C](improvement-plan.md#d1-bridge-strategy). Based on a July 2026 review of the actual source, size, and issue trackers of every relevant bridge implementation, plus the current Agent SDK API surface.

- [Verdict](#verdict)
- [What the alternatives actually look like inside](#what-the-alternatives-actually-look-like-inside)
- [Why the SDK changes the math](#why-the-sdk-changes-the-math)
- [Design: what to build in](#design-what-to-build-in)
- [What to reuse (all MIT)](#what-to-reuse-all-mit)
- [Phased plan](#phased-plan)
- [Risks and honest costs](#risks-and-honest-costs)

## Verdict

**Yes — worth building, with one condition.** A purpose-built bridge is roughly **1.5–2.5k lines and 1–2 weeks** of work, not the multi-month project it would have been pre-SDK, because the Agent SDK absorbs exactly the subsystems that made Takopi 21k lines (session lifecycle, stream parsing, tool plumbing). It also fixes two audit findings *architecturally* (secrets rendered to disk; deny-list weakness) and unlocks everything in improvement-plan Stage 3 (scheduler, heartbeat, memory consolidation) as first-class code instead of bolt-ons.

The condition: **it's worth it only if Stage 3 features are actually wanted.** For a pure capture-and-chat bot, staying on dormant-but-working Takopi costs nothing and a rewrite buys little. The moment a scheduler, digest, structured memory, or safe slash-commands are on the table, those features fight the bridge's limits — and that's when the rewrite pays for itself.

Why not adopt an existing alternative instead:

| Base | Size | Why not |
|---|---|---|
| Takopi (stay forever) | 21.3k lines src, 71 test files | Dormant since May 25, 2026; 27 unmerged PRs (incl. a resume-crash fix, #246); pre-SDK subprocess architecture — every Stage 3 feature would be an external bolt-on. Fine to *stay* on short-term; poor to *build* on |
| RichardAtCT/claude-code-telegram | 19.2k lines, 70 files | 4× more code than a personal bot needs (multi-user auth, SQLite storage layer, FastAPI server); reaches into private SDK APIs (`_internal.message_parser`) — brittle across SDK upgrades; itself quiet since Mar 30, 2026 — same one-maintainer risk class as Takopi, just currently warmer |
| linuz90/claude-telegram-bot | **4.6k lines** | Closest to right-sized — but single-chat assumptions differ, Bun-only, and adopting it wholesale still means maintaining a fork of someone else's opinions. Better used as a **donor** (see below) |
| nanoclaw | 22.6k lines | Excellent SDK hardening patterns, but drags a whole host-router + container-per-group + SQLite-IPC infrastructure that solves multi-group problems this project doesn't have |
| agent-second-brain (tmux) | 3.7k lines | The tmux-scrollback-parsing approach exists solely as a subscription-billing hedge; fragile (TUI parsing, full request serialization). The billing scare that motivated it was reverted (see [Risks](#risks-and-honest-costs)) |

## What the alternatives actually look like inside

Measured from fresh clones, July 13, 2026. All five are MIT-licensed.

**Takopi** (~21.3k lines Python, dormant): plugin architecture with engines (subprocess + stream-JSON per agent CLI) and transports. The heavy lifting is `telegram/loop.py` at **1,984 lines** (polling, message classification, forward coalescing, media-group buffering, per-session queues) and per-engine stream parsers (`codex.py` 1,409 lines vs `claude.py` 486). Its crown jewel: `markdown.py` + `telegram/render.py` (~565 lines) — markdown → Telegram entities with fence-aware splitting that never breaks a code block. Open PRs cluster around: resume crashing on oversized sessions (#246), Windows paths (×3), voice-transcript echo (×2), permissions control from chat (#230).

**RichardAtCT** (~19.2k lines Python + claude-agent-sdk): the useful part is `sdk_integration.py` (767 lines) — `ClaudeSDKClient` streaming client with a `can_use_tool` permission callback validating file/bash operations pre-flight. The rest is enterprise scaffolding (1,755-line orchestrator, ~3,900 lines of handlers, ~2,100-line storage layer, rate limiting, audit, webhooks, APScheduler). Its issue tracker is a preview of scheduler pain: missed jobs while the bot is busy, false "completed" on long tasks, message-chunk stitching bugs.

**linuz90** (~4.6k lines TS/Bun + grammY): proof of how small this can be. The functioning core is **~1,550 lines**: `session.ts` (613) wrapping SDK `query()` with `resume` + on-disk session persistence, `streaming.ts` (343) editing a status message with throttling, `formatting.ts` (309) markdown → Telegram **HTML** with shrink-to-fit under the 4,096-char limit and **plain-text fallback** when HTML breaks at a split boundary, plus two ~150-line in-process MCP servers: `ask_user` (inline buttons for choices) and `send_file`. Everything else is media handlers and safety config.

**nanoclaw** (~22.6k lines TS, very active, 30k★): the most production-hardened SDK invocation in the wild (`container/agent-runner/src/providers/claude.ts`, 481 lines): `query()` with resume **plus fallbacks** — "continuation rotation" against cold resumes, recovery when the transcript `.jsonl` disappears, `CLAUDE_CODE_AUTO_COMPACT_WINDOW` tuning, PreToolUse/PostToolUse/PostToolUseFailure/PreCompact hooks. Security model: `bypassPermissions` inside an OS sandbox instead of permission-callback logic — simpler and sturdier.

**agent-second-brain** (~3.7k lines Python): drives one long-lived interactive Claude Code TUI in tmux via `send-keys` and scrollback parsing. Motivated by Anthropic's May 14, 2026 announcement moving headless/SDK usage to separate paid credits — **which was reverted before taking effect** (June 15–16; SDK and `claude -p` still draw from Pro/Max subscription limits, per the official Help Center). Remaining lessons: isolate cron work from chat work; watchdog everything.

Cross-project pain ranking (by code volume and issue traffic) — where the real work lives:

1. **Markdown rendering + message splitting** — all three Telegram bridges wrote their own; all three have had split-related bugs. This is the #1 underestimated subsystem.
2. **Streaming progress** — throttled `editMessageText` under Telegram rate limits.
3. **Session lifecycle / resume** — oversized-session crashes (Takopi), lost transcripts and cold-resume rotation (nanoclaw), resume in scheduled jobs (RichardAtCT).
4. **Scheduler reliability** — RichardAtCT's top issue theme.
5. **Media groups / forward coalescing** — surprisingly nasty (Takopi has dedicated classes for both).
6. **Voice** — cheap everywhere (~50–350 lines: transcode, POST, insert text).

## Why the SDK changes the math

What Takopi hand-built vs what the SDK now provides:

| Subsystem | Takopi (pre-SDK) | Agent SDK |
|---|---|---|
| Session create/resume/fork | stateless resume tokens + CLI `--resume`, crash-prone on big sessions | `resume`/`fork_session` options; session files under `CLAUDE_CONFIG_DIR`; persist one `session_id` string per chat |
| Stream parsing | hand-parsed `stream-json` stdout per engine (1.4k lines for codex alone) | typed message/event objects incl. partial deltas (`include_partial_messages`) |
| Tool control | writes `~/.claude/settings.json` at container start | `allowed_tools`/`disallowed_tools`/`permission_mode` per call, **`can_use_tool` callback**, **PreToolUse hooks** seeing resolved inputs |
| Custom actions | impossible without forking | in-process MCP tools (`create_sdk_mcp_server`): `send_file`, `ask_user` buttons, `create_note` as typed functions |
| Subagents | n/a | programmatic `AgentDefinition` — e.g. a **read-only URL summarizer** (prompt-injection mitigation D6.1 becomes ~20 lines) |
| System prompt | concatenated CLAUDE.md files on disk | `system_prompt` preset+append, `setting_sources` control |
| Cost tracking | parse CLI output | `total_cost_usd` on every result message |

Direct consequences for the audit findings:

- **S2 (secrets in TOML on a volume)** disappears: no config file is rendered; the bot token and API key live only in process env.
- **S3 (deny-list bypasses)** gets a real fix: a PreToolUse hook denies `Write`/`Edit`/`Bash` targeting paths outside `/vault` *after* path resolution, and logs every mutating call to an audit file — pattern-matching on command prefixes stops being the security boundary.
- **Stage 3 scheduler** becomes an in-process asyncio loop sharing the session store — no sidecar container, no `claude -p` cold starts, and the "missed jobs while busy" failure mode RichardAtCT users hit is handled with a simple queue.

Billing note: the SDK runs Claude Code under the hood and inherits its auth — **both** `ANTHROPIC_API_KEY` (this project's current default) and Pro/Max subscription login work, per Anthropic's Help Center as of July 2026. The June 2026 scare (separate credits for programmatic use) was reverted before taking effect, but it is a precedent worth tracking.

## Design: what to build in

### Scope principles

- **Single chat, single vault, single engine.** No multi-user auth layer, no multi-project routing, no topics, no engine plugins. This is what deletes 80% of Takopi's and RichardAtCT's code.
- **Keep the containment story** (the project's differentiator vs. OpenClaw-class agents): claim-token chat binding, Docker isolation, deny-by-default outside `/vault`, kill-phrase.
- **Vault-as-config**: schedules, memory templates, and skills live as markdown in the vault (synced, user-editable in Obsidian) — not in TOML.

### Language

| | Pros | Cons |
|---|---|---|
| **TypeScript (recommended)** | SDK's reference implementation; both best donors (linuz90 skeleton, nanoclaw hardening) are TS; grammY is excellent; Bun or Node 22 single-binary-ish deploys | Team familiarity may favor Python; new container base (already have `node:22-alpine` for obsidian-headless) |
| Python | aiogram mature; Takopi's render code is a Python donor; matches current container | SDK Python wrapper trails TS; best minimal donors are TS |

### Components (~1.5–2.5k lines total)

1. **Transport** (~300 lines): grammY long-polling; claim-token binding (port the existing flow); text/voice/photo/document handlers; forward coalescing can wait.
2. **Session manager** (~400 lines): chat → `session_id` persisted in the state volume; `/new`, `/cancel`; **resume fallbacks from day one** (nanoclaw lesson): on resume failure, start fresh and say so; queue per chat (serialize turns, buffer messages arriving mid-turn — Takopi's steering pattern).
3. **Renderer** (~350 lines): markdown → Telegram **HTML** (not MarkdownV2 — unanimous lesson), fence-aware splitting, shrink-to-fit, plain-text fallback on parse failure at split boundaries.
4. **Streaming status** (~300 lines): one status message edited with throttle (respect Telegram ~1 edit/sec/chat); map `content_block_start(tool_use)` → "✏️ Editing Inbox/idea.md…", text deltas → final answer.
5. **Security layer** (~200 lines): `permission_mode` + `allowed_tools` from env (compatible with today's `CLAUDE_ALLOWED_TOOLS`/`CLAUDE_DENIED_COMMANDS`); PreToolUse hook: resolved-path check against `/vault` + trash-instead-of-delete enforcement + JSONL audit log; kill-phrase handler that aborts the running turn.
6. **Custom tools** (~250 lines, in-process MCP): `send_file` (agent pushes a note/export into the chat), `ask_user` (inline buttons; the agent can ask "file under Projects or Areas?" instead of guessing), `schedule_task` (writes a validated entry into `vault/schedules/` — natural-language self-scheduling with a typed gate instead of freehand file writes).
7. **Scheduler** (~300 lines): asyncio cron loop sweeping `vault/schedules/*.md` (YAML header: cron, model, enabled); runs due tasks as fresh SDK sessions (Haiku default); posts results to the bound chat; jobs queue behind interactive turns, never overlap; morning-digest and inbox-cleanup templates shipped disabled.
8. **Voice** (~150 lines): ffmpeg ogg→(whatever the endpoint needs), POST to an OpenAI-compatible transcription URL (works for OpenAI, Groq, Voxtral, or a local sidecar unchanged from today's env vars).
9. **Subagents** (config, ~50 lines): read-only `url-summarizer` AgentDefinition (`Read`/`WebFetch` only, no write tools) used by instruction for forwarded links — the D6.1 prompt-injection mitigation, nearly free here.

Explicit non-goals (revisit only on demand): forum topics, media groups, multiple engines (Codex etc.), multi-chat, web dashboard, TTS replies.

### Compatibility contract

The new bridge must consume the **same env surface** (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`/claim flow, `CLAUDE_MODEL`, `CLAUDE_ALLOWED_TOOLS`, `CLAUDE_DENIED_COMMANDS`, `VOICE_*`) and the same `/vault` + state-volume layout, so `docker-compose.yml` swaps one image and nothing else changes for existing installs.

## What to reuse (all MIT)

| From | Take | Saves |
|---|---|---|
| linuz90/claude-telegram-bot | overall skeleton; `formatting.ts` (HTML render + shrink + plain fallback); `streaming.ts` (throttled status edits); `ask_user` / `send_file` MCP-server pattern | ~1 week of the ugliest work |
| nanoclaw `providers/claude.ts` | production SDK invocation: resume fallbacks / continuation rotation, lost-transcript recovery, hook wiring, compact-window tuning | the bugs you'd otherwise find in production |
| Takopi | fence-aware split algorithm (if Python is chosen: `markdown.py` + `render.py` nearly verbatim); claim/binding UX (already this project's, reimplement trivially); per-session queue semantics | render edge cases |
| RichardAtCT | `can_use_tool` validation patterns (only if permission-callback gating is wanted on top of hooks) | reference, not code |

## Phased plan

| Phase | Content | Exit criteria | Complexity |
|---|---|---|---|
| **0 — Spike** | Text-only bot: polling → SDK `query()` with resume → HTML render + split → reply. Runs as a compose *profile* (`bridge-next`) with a separate test bot token, side-by-side with Takopi against the same vault (read-only allowlist during the spike) | Round-trip conversation with context continuity across bot restarts; honest feel-check vs Takopi | **M** (2–4 days) |
| **1 — Parity** | Streaming status, voice (OpenAI-compatible URL), claim binding, `/new` `/cancel`, security hooks + audit log, kill-phrase, session-queue, env-surface compatibility | Daily-drivable replacement for *this project's used subset* of Takopi; existing `.env` works unchanged | **L** (1–2 weeks) |
| **2 — Beyond Takopi** | Custom tools (`ask_user`, `send_file`, `schedule_task`), scheduler + digest/inbox-cleanup templates, read-only URL-summarizer subagent, memory templates hookup (improvement-plan 3.2) | The Stage 3 feature set nothing else offers in one place | **L** (1–2 weeks, incremental) |
| **3 — Cutover** | New bridge becomes compose default; Takopi kept as a fallback profile for one release cycle; migration + rollback docs; CHANGELOG major entry | One release with both; then Takopi image demoted to `docs/legacy` | **M** |

Total honest estimate: **3–5 weeks of part-time work** spread across releases, with a usable daily driver after Phase 1. Phase 0 is deliberately cheap — if the spike feels worse than Takopi in daily use, stop, having spent 2–4 days, and fall back to improvement-plan option D1.A (stay) with the sidecar scheduler (3.1.A) instead.

## Risks and honest costs

- **Maintenance moves in-house.** Telegram Bot API changes, SDK major versions, model deprecations — all become this repo's problem. Mitigation: the surface is small (~2k lines), pinned, and covered by the Phase 1 test suite; contrast with the current state where the same risk exists *plus* a dormant middleman.
- **SDK policy risk.** The June 2026 billing scare was reverted, but it happened. On API-key billing (this project's default) it was never a threat; subscription users should treat that mode as best-effort. Track the Help Center article.
- **Private-API temptation.** RichardAtCT's breakages show the cost of touching `_internal`. Rule: public API only; pin the SDK version; CI-test against the pinned version.
- **Feature envy.** The failure mode that made the alternatives 20k lines. The non-goals list above is part of the design; additions require removing something or a demonstrated need.
- **Solo-project bus factor** — the same critique aimed at Takopi applies here. Difference: this bridge is ~2k lines purpose-built for one stack (a weekend to re-understand), not 21k lines of general-purpose plugin architecture.

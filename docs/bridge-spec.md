---
title: "Bridge spec — Obsidian Telegram Agent"
description: "Build specification for the purpose-built Telegram bridge on the Claude Agent SDK: full feature set (Takopi parity checklist plus new capabilities), architecture, env contract, testing strategy, and phased build plan."
---

# Bridge spec: the purpose-built bridge on the Claude Agent SDK

← Back to [docs index](README.md)

The [SDK bridge plan](sdk-bridge-plan.md) answered *whether* to build (yes, conditionally) and surveyed what every alternative looks like inside. **The decision has been made to build.** This document is the *what*: the complete feature specification, the Takopi-parity checklist (nothing loved gets lost), the new capabilities that justify the rewrite, and the build plan.

Working name for the component: **bridge** (directory `bridge/`, compose service `bridge`, image `…/bridge`).

- [Goals and non-goals](#goals-and-non-goals)
- [Architecture](#architecture)
- [Takopi parity checklist](#takopi-parity-checklist)
- [Feature specification](#feature-specification)
- [Environment contract](#environment-contract)
- [Testing and CI](#testing-and-ci)
- [Phased build plan](#phased-build-plan)
- [Risks](#risks)

## Goals and non-goals

**Goals**

1. **Full replacement of the used Takopi subset** — a daily driver that feels at least as good, with the same `.env` working unchanged.
2. **Fix the audit findings architecturally** — no secrets rendered to disk (S2), resolved-path enforcement instead of pattern deny-lists as the boundary (S3), a technical prompt-injection mitigation (S4).
3. **Make the vault recoverable** — turn the README's "the agent can mangle your notes" warning from a disclaimer into a feature: every turn checkpointed, `/undo` in chat.
4. **Own the money story** — first-class support for alternative Anthropic-compatible providers (AI Tunnel and friends), plus a bridge-level budget guard, because aggregator keys have no Anthropic-console spend limits.
5. **Unlock Stage 3** of the [improvement plan](improvement-plan.md) — scheduler, digest, heartbeat, memory, skills — as first-class code, not bolt-ons.

**Non-goals** (revisit only on demonstrated need — this list is what keeps the bridge ~2.5k lines instead of 20k)

- Multi-user auth, multi-chat routing, multi-project
- Telegram forum topics
- Multiple engines (Codex, Gemini CLI, …) — Claude Code via the Agent SDK only
- Web dashboard, webhook API server
- TTS replies
- Windows host support

## Architecture

| Decision | Choice | Rationale |
|---|---|---|
| Language | **TypeScript, Node 22** | SDK reference implementation is TS; both donor codebases (linuz90, nanoclaw) are TS; `node:22-alpine` base already in the stack |
| Telegram library | **grammY** | Long-polling, typed, excellent middleware; used by the best donor |
| Agent runtime | **`@anthropic-ai/claude-agent-sdk`**, public API only, version pinned | The whole premise; `_internal` is banned (RichardAtCT's breakage lesson) |
| Process model | Single container, single process: grammY loop + per-chat turn queue + asyncio-style scheduler tick | One thing to deploy, one thing to healthcheck |
| State | `bridge-state/` volume: `chat_id`, `session.json` (per-chat session id + metadata), `spend.json`, `audit.jsonl`, checkpoints git dir | Same pattern as `takopi-state/`, but **no secrets ever written** — tokens live only in process env |
| Provider | Anthropic direct **or any Anthropic-Messages-compatible base URL** via `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` passthrough | AI Tunnel et al. work for both interactive and scheduled runs with zero extra code |
| Rollout | Compose **profile `bridge`** side-by-side with Takopi (separate test bot token) until cutover | Phase 0/1 run risk-free against the same vault |

Component budget (~2.5–3k lines — slightly above the assessment's estimate because of the new safety/money features):

```
bridge/src/
  transport/     grammY setup, claim binding, media handlers, coalescing   ~400
  session/       session store, resume + fallbacks, turn queue, steering   ~450
  render/        markdown → Telegram HTML, fence-aware split, fallbacks    ~350
  status/        streaming progress message, reactions, error UX           ~300
  safety/        PreToolUse hooks, audit log, kill-phrase, checkpoints     ~350
  money/         cost tracking, budget guard, /usage                       ~200
  tools/         in-process MCP: ask_user, send_file, schedule_task        ~250
  scheduler/     cron sweep of vault/schedules, queueing, templates        ~300
  skills/        vault/skills registry → dynamic slash-commands            ~150
  voice/         ffmpeg + OpenAI-compatible transcription                  ~150
```

## Takopi parity checklist

Every Takopi behavior this stack uses (or that users of it love), and its fate in the bridge. Nothing is silently dropped.

| Takopi feature | Bridge status | Notes |
|---|---|---|
| Chat session mode (auto-resume every message) | ✅ Phase 0 | SDK `resume`; one `session_id` per chat in `session.json` |
| `/new`, `/cancel` | ✅ Phase 1 | `/cancel` also available as an inline button on the progress message |
| Per-session turn serialization + queueing | ✅ Phase 1 | One turn at a time; messages arriving mid-turn are queued |
| **Steering** (mid-turn messages injected into the running turn) | ✅ Phase 1 | SDK streaming input; plus 0.23.4-style **Steer / Queue / Cancel** inline buttons on the progress message — better than the pinned Takopi 0.22.3 |
| Markdown rendering that never breaks a code block | ✅ Phase 0 | HTML parse mode (not MarkdownV2 — unanimous ecosystem lesson), fence-aware splitting, shrink-to-fit, plain-text fallback |
| Message overflow `split`/`trim` | ✅ Phase 1 | `TAKOPI_MESSAGE_OVERFLOW` honored under a new alias, old name still read |
| Resume-line footer (session id under replies) | ✅ Phase 1 | Extended: optional cost footer (see F6) |
| Voice-note transcription (OpenAI-compatible URL) | ✅ Phase 1 | Same env vars; adds optional **transcript echo** ("🎤 …") — fixes the double-echo bug class Takopi has open PRs for |
| Forward coalescing (several forwards → one turn) | ✅ Phase 1 | **Promoted from "can wait"**: forwarding articles is this project's headline use case; N forwards within a short window become one prompt |
| Media groups (album → one turn) | ✅ Phase 2 | Rides on the coalescing buffer |
| Progress indication while the agent works | ✅ Phase 1 | Upgraded from Takopi's static notice to a live-edited status line (F4) |
| Backlog processing after downtime | ✅ Phase 1 | Correct `getUpdates` offset handling; messages sent while the container was down are processed on boot, oldest first |
| `/claim` chat binding | ✅ Phase 1 | Ported as-is (it's this project's flow anyway); same `chat_id` persistence semantics |
| `/reasoning` toggle (Takopi 0.23.4) | ✅ Phase 2 | Maps to SDK thinking configuration per session |
| Forum topics | ❌ non-goal | Single-chat design |
| Multi-engine (Codex etc.) | ❌ non-goal | Claude Code only |
| Multi-project routing | ❌ non-goal | One vault |

## Feature specification

Grouped F1–F13. Each carries the phase it lands in.

### F1. Transport & chat UX (Phase 0–1)

- grammY long-polling; single bound chat via the existing claim-token flow.
- **Forward coalescing**: messages forwarded within a ~2 s window buffer into one turn ("save these 3 articles" just works).
- **Reactions as lightweight status**: 👀 on receipt, ✅ on success, ⚠️ on error — the chat stays readable without a wall of status messages; configurable off.
- **Structured error UX**: provider/network errors produce one friendly message with a **Retry** button and exponential backoff — never a raw stack trace, never a silent hang.
- **Localization** of all bot-authored strings (`BRIDGE_LOCALE=en|ru`), because the bot's operator here reads Russian; agent output language stays whatever `CLAUDE.md` dictates.

### F2. Sessions (Phase 0–1)

- SDK `query()` with `resume`; session id persisted per chat.
- **Resume fallbacks from day one** (nanoclaw's lesson): on resume failure → start fresh, tell the user in one line, keep the old id in `session.json` history for manual recovery. No crash-on-oversized-session (Takopi #246 class).
- Turn queue with steering: mid-turn messages offer **Steer** (inject into the running turn), **Queue** (run after), **Cancel current**.
- **Session-size awareness**: the SDK reports usage per result; when a session crosses a configurable context threshold the bridge appends a one-line hint with a **Start fresh** button — the "context accumulates" foot-gun from [sessions.md](sessions.md) gets a UI instead of a docs paragraph.
- `/sessions` (Phase 4, on demand): list recent sessions with resume buttons.

### F3. Rendering (Phase 0)

Markdown → Telegram **HTML**; fence-aware splitting that never cuts inside a code block; shrink-to-fit under the 4,096-char limit; plain-text fallback when HTML parsing fails at a split boundary. Donor: linuz90 `formatting.ts`, hardened with golden tests (see [Testing](#testing-and-ci)).

### F4. Streaming status (Phase 1)

One status message edited with throttling (≤1 edit/sec/chat):

```
🤔 thinking…
📖 Reading Inbox/2026-07-16.md
✏️ Editing Projects/homelab.md
```

Tool events map to human lines with the target path; text deltas replace the status with the final answer. The status message hosts the Cancel/Steer buttons.

### F5. Safety: enforcement, audit, recovery (Phase 1–2) — *the differentiator*

- **PreToolUse hook**: deny `Write`/`Edit`/`Bash` whose *resolved* target path escapes `/vault`; enforce trash-instead-of-delete; consume `.agentignore` (improvement-plan D7.L1) as deny patterns. Pattern deny-lists (`CLAUDE_DENIED_COMMANDS`) remain honored for compatibility but stop being the security boundary.
- **Audit log**: every mutating tool call appended to `bridge-state/audit.jsonl` (timestamp, tool, resolved path, session id).
- **Kill-phrase**: a configurable plain-text phrase (default `STOP AGENT`) aborts the running turn and pauses the scheduler until re-enabled.
- **Turn checkpoints + `/undo` + `/diff`** (Phase 2, new capability): before the first mutating tool call of each turn, the bridge snapshots `/vault` into a **shadow git repo** (`GIT_DIR` in `bridge-state/checkpoints.git`, work-tree `/vault` — the vault itself stays free of a visible `.git`).
  - `/undo` reverts the last turn's changes (with a confirmation button showing the file list); `/diff` shows what the last turn touched.
  - Scheduler runs are checkpointed the same way.
  - Retention: prune snapshots older than `BRIDGE_CHECKPOINT_DAYS` (default 14).
  - This does **not** replace off-VPS backups ([backups.md](backups.md) stands), but it converts the most common failure — "the agent mangled a note and I noticed immediately" — from an incident into a two-tap recovery.

### F6. Money: cost visibility and budget guard (Phase 2)

- Per-turn cost from the SDK's `total_cost_usd`; optional footer (`💰 $0.0042 · session $0.31`) controlled by the same flag family as the resume line.
- `/usage`: today / this week / this month, by interactive vs scheduled, from `spend.json`.
- **Budget guard**: `BRIDGE_DAILY_BUDGET_USD` / `BRIDGE_MONTHLY_BUDGET_USD`; at 80% the bridge warns in chat, at 100% it refuses new turns (override button for the bound user). Critical when the key is an aggregator key (AI Tunnel) with no Anthropic-console spend limits behind it.
- Works identically on Anthropic direct or any `ANTHROPIC_BASE_URL` provider.

### F7. Custom in-process MCP tools (Phase 3)

- `ask_user`: the agent asks a multiple-choice question rendered as inline buttons ("File under Projects or Areas?") instead of guessing. Timeout → agent proceeds with its best guess and says so.
- `send_file`: the agent pushes a note/export/attachment into the chat as a document.
- `schedule_task`: the agent writes a *validated* entry into `vault/schedules/` (typed gate: cron expression, model, enabled flag) — natural-language self-scheduling ("remind me Thursday") without freehand file writes.

### F8. Scheduler, digest, heartbeat (Phase 3)

- In-process cron loop sweeping `vault/schedules/*.md` (YAML header: `cron`, `model`, `enabled`; body = prompt). Tasks are markdown **in the vault** → synced, phone-editable in Obsidian.
- Due tasks run as fresh SDK sessions (Haiku default), queued behind interactive turns, never overlapping; results post to the bound chat; missed-while-busy jobs run late rather than never (RichardAtCT's top issue class, solved by the shared queue).
- Shipped templates, disabled by default: `morning-digest.md`, `inbox-cleanup.md`, `heartbeat.md` ("check inbox and schedules; message me only if actionable" — the OpenClaw signature), `secret-scan.md` (D7.L3 once gitleaks is in the image).

### F9. Subagents (Phase 3)

- Read-only **`url-summarizer`** `AgentDefinition` (`Read`/`WebFetch` only, no write tools): forwarded links are fetched and summarized in a context that *cannot* write to the vault or shell out; the main agent files the summary. This is the D6.1 prompt-injection mitigation, ~20 lines here.

### F10. Media and vision (Phase 3)

- **Photos** → passed to the agent as images (Claude vision): whiteboard shots become structured notes, receipts get filed; original saved under `vault/attachments/`.
- **Documents** (PDF, text files ≤ Telegram bot limits) → saved to `vault/attachments/`, referenced in the turn prompt for processing.

### F11. Skills as markdown → dynamic slash-commands (Phase 3)

- `vault/skills/*.md` (YAML header: `command`, `description`; body = prompt template with `{{args}}`) auto-register as Telegram bot commands on boot and on file change.
- Ships with `/capture`, `/append`, `/summarize` — the README roadmap's "safe slash-commands", implemented as user-editable vault files rather than code. Editing a skill from Obsidian on the phone updates the bot.

### F12. Memory hookup (Phase 3)

- Templates and `CLAUDE.base.md` instructions from improvement-plan 3.2 (`vault/memory/USER.md`, daily logs); consolidation ships as a `schedules/` task. The bridge itself only needs to *not* get in the way — memory is vault content.

### F13. Ops in chat (Phase 2)

- `/status`: bridge uptime, current session id + approximate context fill, Obsidian Sync state (via the shared volume's sync marker or `ob` status where available), last scheduler runs, today's spend, checkpoint count.
- `/model`: show current model; `/model haiku|sonnet|<full-id>` switches for the *next* sessions (persisted). Scheduled tasks keep their per-task `model` header.
- `/help`: generated from the command registry, including vault-defined skills.

## Environment contract

Existing `.env` files keep working. The bridge reads the current surface and adds a small, prefixed set:

| Variable | Status |
|---|---|
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (+claim flow), `CLAUDE_MODEL`, `CLAUDE_ALLOWED_TOOLS`, `CLAUDE_DENIED_COMMANDS`, `CLAUDE_EXTRA_INSTRUCTIONS`, `VOICE_*`, `TZ` | **Honored unchanged** |
| `TAKOPI_SESSION_MODE`, `TAKOPI_MESSAGE_OVERFLOW`, `TAKOPI_SHOW_RESUME_LINE` | Honored as legacy aliases of `BRIDGE_*` equivalents |
| `ANTHROPIC_API_KEY` | Honored (Anthropic direct) |
| `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` | **New**: Anthropic-compatible providers (AI Tunnel etc.); when `ANTHROPIC_AUTH_TOKEN` is set, `ANTHROPIC_API_KEY` is ignored and never forwarded |
| `BRIDGE_LOCALE`, `BRIDGE_DAILY_BUDGET_USD`, `BRIDGE_MONTHLY_BUDGET_USD`, `BRIDGE_CHECKPOINT_DAYS`, `BRIDGE_KILL_PHRASE`, `BRIDGE_REACTIONS`, `BRIDGE_COST_FOOTER` | **New**, all with safe defaults |

Volumes: same `./vault`; `./bridge-state` replaces `./takopi-state` (migration note in cutover docs — only `chat_id` is worth carrying over, and the installer does it automatically). **No secrets are ever written to the state volume** — this closes audit finding S2 by construction.

## Testing and CI

The no-tests status quo (audit 1.4) does not carry over. Minimum bar per phase:

- **Renderer golden tests** (Phase 0): a corpus of nasty markdown (nested fences, long lines, entities at split boundaries, RU text) → expected HTML chunks. This is the #1 bug source in every existing bridge; it gets the most tests.
- **Splitter property tests** (Phase 0): for random inputs — no chunk exceeds 4,096 chars, code fences balanced per chunk, concatenation round-trips.
- **Unit tests** for session store, budget math, schedule-header parsing, `.agentignore` → deny-pattern expansion (Phase 1–2).
- **E2E against a fake Bot API server** (Phase 1): boot the bridge with a mock Telegram endpoint and a stub SDK; assert claim flow, turn queue, steering, error UX.
- **Pinned-SDK CI**: the SDK version is pinned; CI runs against exactly that version; Dependabot proposes bumps that must pass the suite before merge.

## Phased build plan

| Phase | Content | Exit criteria | Effort |
|---|---|---|---|
| **0 — Spike** | Text-only: polling → SDK `query()` + resume → HTML render/split → reply. Runs as compose profile `bridge` with a separate test bot token, side-by-side with Takopi on the same vault (read-only allowlist). Renderer/splitter tests. | Round-trip conversation with continuity across restarts; honest feel-check vs Takopi. **Stop here if it feels worse.** | 2–4 days |
| **1 — Parity+** | Claim binding, `/new` `/cancel`, turn queue + steering buttons, streaming status, reactions, error UX, voice, forward coalescing, backlog processing, PreToolUse enforcement + audit + kill-phrase, env compatibility, localization, E2E suite | Daily driver replacing the used Takopi subset; existing `.env` works unchanged; write access enabled | 1–2 weeks |
| **2 — Safety & money** | Checkpoints + `/undo` + `/diff`, budget guard + `/usage` + cost footer, `/status`, `/model`, session-size hints, media groups, `/reasoning` | The two headline differentiators (recoverable vault, hard budget) live | ~1 week |
| **3 — Agentic** | MCP tools (`ask_user`, `send_file`, `schedule_task`), scheduler + digest/heartbeat/cleanup templates, `url-summarizer` subagent, photos/documents, skills registry, memory templates | The Stage 3 feature set nothing else offers in one place | 1–2 weeks |
| **4 — Cutover** | Bridge becomes compose default; Takopi demoted to a fallback profile for one release, then `docs/legacy`; state migration; docs rewrite (sessions, security, configuration); CHANGELOG major | One release shipping both; the next shipping bridge-only | ~1 week incl. docs |

Total: **5–7 weeks part-time**, usable daily driver after Phase 1 (~2 weeks in). Order within phases is flexible; the phase *gates* are not — no write access before the safety hooks exist, no cutover before the E2E suite is green.

## Risks

Inherited from the [assessment](sdk-bridge-plan.md#risks-and-honest-costs) (maintenance in-house, SDK policy watch, no `_internal`, feature envy, bus factor) — all still apply. New ones introduced by this spec:

- **Checkpoint interplay with Obsidian Sync**: a sync pull can land between snapshot and `/undo`, making the revert clobber a legitimate remote edit. Mitigation: `/undo` shows the file list and warns when files changed *after* the checkpoint; per-file revert selection if it proves common in practice.
- **Budget guard accuracy on aggregators**: `total_cost_usd` reflects Anthropic list prices, not the provider's markup. Mitigation: `BRIDGE_COST_MULTIPLIER` (default 1.0) documented next to the AI Tunnel setup; the guard is a safety net, not accounting.
- **Scope creep via F7–F13**: the feature list above is the ceiling, not the floor. Anything not listed needs a removal or a demonstrated need first — same rule as the assessment's non-goals.

---
title: "Bridge spec — Obsidian Telegram Agent"
description: "Build specification for the purpose-built agent bridge on the Claude Agent SDK: full feature set, what Takopi's retirement takes with it, architecture, env contract, testing strategy, and phased build plan. Self-hosted web client only — the Telegram transport is dropped."
---

# Bridge spec: the purpose-built bridge on the Claude Agent SDK

← Back to [docs index](README.md)

The [SDK bridge plan](sdk-bridge-plan.md) answered *whether* to build (yes, conditionally) and surveyed what every alternative looks like inside. **The decision has been made to build.** This document is the *what*: the complete feature specification, what Takopi's retirement takes with it, the new capabilities that justify the rewrite, and the build plan.

Working name for the component: **bridge** (directory `bridge/`, compose service `bridge`, image `…/bridge`). The name is now a slight misnomer — it bridges nothing but its own client — and it is kept because renaming a component mid-spec costs more than it clarifies.

- [Goals and non-goals](#goals-and-non-goals)
- [Architecture](#architecture)
- [What Takopi's retirement takes with it](#what-takopis-retirement-takes-with-it)
- [Feature specification](#feature-specification)
- [Environment contract](#environment-contract)
- [Deployment and operations](#deployment-and-operations)
- [Testing and CI](#testing-and-ci)
- [Phased build plan](#phased-build-plan)
- [Risks](#risks)

## Goals and non-goals

**Goals**

1. **Take over Takopi's job** — everything the vault is actually driven with today (capture, resume, voice, articles), from the phone, at least as good. Not *parity*: the transport Takopi bridged is gone, so the bar is the job, not the interface.
2. **Fix the audit findings architecturally** — no secrets rendered to disk (S2), resolved-path enforcement instead of pattern deny-lists as the boundary (S3), a technical prompt-injection mitigation (S4).
3. **Make the vault recoverable** — turn the README's "the agent can mangle your notes" warning from a disclaimer into a feature: every turn checkpointed, one-tap undo.
4. **Own the money story** — first-class support for alternative Anthropic-compatible providers (AI Tunnel and friends), plus a bridge-level budget guard, because aggregator keys have no Anthropic-console spend limits.
5. **Unlock Stage 3** of the [improvement plan](improvement-plan.md) — scheduler, digest, heartbeat, memory, skills — as first-class code, not bolt-ons.

**Non-goals** (revisit only on demonstrated need — this list is what keeps the bridge ~2k lines instead of 20k)

- **A Telegram transport** — dropped, see below
- Multi-user auth, multi-chat routing, multi-project
- Multiple engines (Codex, Gemini CLI, …) — Claude Code via the Agent SDK only
- Webhook API for third-party integrations
- TTS replies
- Windows host support

> **Scope change (July 2026), in three parts — one decision each, but they compound.**
>
> **1. A self-hosted web client (PWA) is in scope** — see [web-client-spec.md](web-client-spec.md). Telegram has been officially blocked/degraded in Russia since February 2026, which forces the operator onto a VPN and defeats the AI-Tunnel motivation; and Telegram's single linear session model erases history a web client can keep browsable. A public multi-user web SaaS remains a non-goal.
>
> **2. Hosting moves home.** Off the rented VPS entirely and onto the operator's **home server under Coolify**, published through the homelab's existing tiered wildcard routing as tier A `agent.app.syntexia.ru` — the edge (Traefik on the homelab's public-facing VPS) terminates TLS, Authentik authenticates. The code contract this imposes is in [Deployment target](#deployment-target-the-home-server-under-coolify). It deletes the web client's entire authentication subsystem: Authentik does it.
>
> **3. The Telegram transport is dropped, not demoted.** Telegram stopped being a viable transport in Russia, and hosting at home removes the last network from which the bot could have polled it. Rather than ship a client that needs the VPN the whole stack exists to avoid, support is **removed for now** — the `Transport` interface stays as the seam, so it can come back as an adapter if the situation changes, but nothing in this plan builds or maintains it. What that deletes is not a module: it is grammY, the claim flow, the Telegram-HTML renderer, the fence-aware splitter, the 4,096-char overflow logic, the status-message editing throttle, the Bot API test harness, and the entire Takopi-compatibility surface of the env contract. See [What Takopi's retirement takes with it](#what-takopis-retirement-takes-with-it).
>
> The three compound: **the VPS existed in this plan only to poll Telegram from a network where that works.** No Telegram, no reason for a VPS — the two decisions are one, and the phase plan collapses from two tracks into one sequence.

## Architecture

| Decision | Choice | Rationale |
|---|---|---|
| Language | **TypeScript, Node 22** | SDK reference implementation is TS; both donor codebases (linuz90, nanoclaw) are TS; `node:22-alpine` base already in the stack |
| Client | **Self-hosted web PWA only** ([web-client-spec.md](web-client-spec.md)), served by this process | Telegram is not a transport the operator can reach; a client on their own domain is |
| Transports | **`Transport` interface retained with one implementation** (web) | It cost ~50 lines and has now earned them twice: it is why dropping Telegram is a deletion rather than a rewrite, and why re-adding it later would be an adapter rather than a project |
| Hosting | **Home server under Coolify**, published as tier A `agent.app.syntexia.ru` behind the homelab's edge Traefik and Authentik (homelab `docs/guides/app-deploy-requirements.md`) | Domain, TLS, CrowdSec and SSO already exist at the edge; the bridge ships one plain-HTTP port, no certificates, and no login code. **This project owns no VPS** — the edge is homelab infrastructure it is published through, not deployed to |
| Agent runtime | **`@anthropic-ai/claude-agent-sdk`**, public API only, version pinned | The whole premise; `_internal` is banned (RichardAtCT's breakage lesson) |
| Process model | Single container, single process: HTTP/WS server + per-session turn queue + scheduler tick | One thing to deploy, one thing to healthcheck |
| State | `bridge-state/` volume: `sessions/` (ids + metadata + display transcripts), `spend.json`, `audit.jsonl`, push subscriptions, checkpoints git dir | Same pattern as `takopi-state/`, but **no secrets ever written** — tokens live only in process env |
| Provider | Anthropic direct **or any Anthropic-Messages-compatible base URL** via `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` passthrough | AI Tunnel et al. work for both interactive and scheduled runs with zero extra code |
| Rollout | Built and run **alongside the legacy Takopi stack**, against the same vault, until cutover retires both it and the VPS it runs on | Phases 0–1 stay risk-free; the operator keeps whatever Telegram access they still have until the client replaces it |

Component budget (**~2–2.4k lines**, down from ~2.5–3k — the Telegram deletions outweigh the safety/money additions):

```
bridge/src/
  transport/     Transport interface only (one implementation: web)         ~50
  web/           web adapter: REST + WS API, proxy-auth check, capture
                 and upload entry points, Web Push
                 (frontend in web-client-spec.md, ~2.5k more)              ~650
  session/       session store, resume + fallbacks, turn queue, steering   ~450
  events/        SDK tool/text events → structured turn timeline,
                 error UX                                                  ~150
  safety/        PreToolUse hooks, audit log, kill-phrase, checkpoints     ~350
  money/         cost tracking, budget guard, usage aggregation            ~200
  tools/         in-process MCP: ask_user, send_file, schedule_task        ~250
  scheduler/     cron sweep of vault/schedules, queueing, templates        ~300
  skills/        vault/skills registry → composer chips + prompts          ~150
  voice/         ffmpeg + OpenAI-compatible transcription                  ~150
```

Gone from the budget, and worth naming because it is the single best consequence of the decision: **`render/` (~350) and the Telegram half of `transport/` (~400) do not exist.** Markdown → Telegram HTML, fence-aware splitting that must never cut inside a code block, shrink-to-fit under 4,096 chars, plain-text fallback at a failed split boundary, the ≤1-edit/sec status throttle — the acknowledged #1 bug source in every Telegram bridge, and the subsystem this spec was about to spend its largest test budget on. The web client renders markdown itself, at any length, in the browser.

## What Takopi's retirement takes with it

This was a Takopi-parity checklist while the bridge was replacing Takopi on the same transport. Dropping Telegram changes the question from "does the bridge match Takopi?" to "does anything the vault is actually driven with get lost?" — and the honest answer is that some of it was never a *feature*, only Telegram's tax. The point of the section stands: nothing is silently dropped.

| Takopi feature | Fate | Notes |
|---|---|---|
| Chat session mode (auto-resume every message) | ✅ **kept, better** | SDK `resume`, and sessions stop being one per chat: they are first-class, browsable, individually resumable (F2) |
| `/new`, `/cancel` | ✅ kept | Buttons in the client rather than commands |
| Per-session turn serialization + queueing | ✅ kept | Core, transport-independent |
| **Steering** (mid-turn messages injected into a running turn) | ✅ kept | SDK streaming input; Steer / Queue / Cancel inline in the chat pane |
| Voice-note transcription (OpenAI-compatible URL) | ✅ **kept, better** | Same `VOICE_*` env vars; the pipeline is transport-agnostic. The transcript is now editable *before* send (W-F4) instead of firing blind |
| Forward coalescing (several forwards → one turn) | ✅ **kept, better** | The headline use case survives as the Android **share sheet** (W-F3): share N links from any app, not just from Telegram. Coalescing a burst into one turn stays |
| Media groups (album → one turn) | ✅ kept | Multi-file share |
| Progress indication while the agent works | ✅ **kept, better** | A live timeline fed by SDK events (F4), with no edit-rate throttle to design around |
| `/reasoning` toggle | ✅ kept | A per-session setting |
| Markdown rendering that never breaks a code block | 🗑️ **problem deleted** | Not ported — *dissolved*. The client renders markdown in the browser: no parse mode, no fence-aware splitter, no shrink-to-fit, no plain-text fallback |
| Message overflow `split`/`trim` | 🗑️ problem deleted | There is no 4,096-char limit to overflow |
| Resume-line footer (session id under replies) | 🗑️ problem deleted | The session is a labelled thing in a sidebar; it does not need to announce its id under every reply. Cost display survives as UI (F6) |
| Backlog processing after downtime | ⚠️ **replaced, not ported** | No `getUpdates` offset to manage. The equivalent — "capture something while the bridge is down" — moves client-side to the PWA's offline queue (W-F3), and only exists from Phase 3 on. Between Phase 1 and 3 there is no offline capture; that is a known, accepted gap |
| `/claim` chat binding | 🗑️ **replaced by Authentik** | No bot token, no chat to bind, no claim token to leak in logs. Takes audit finding R1 (the blocking claim loop that reports `unhealthy` forever) with it |
| Telegram transport | ❌ **dropped for now** | Blocked/degraded in RU; the home network cannot poll it. The `Transport` seam remains so this is reversible |
| Forum topics | ❌ non-goal | Moot |
| Multi-engine (Codex etc.) | ❌ non-goal | Claude Code only |
| Multi-project routing | ❌ non-goal | One vault |

Net: of the nine behaviors worth keeping, five come back *better* and four were Telegram's tax, not Takopi's value. The one real regression is the offline-capture gap between Phase 1 and Phase 3.

## Feature specification

Grouped F1–F13. Each carries the phase it lands in.

### F1. Transport seam & chat UX (Phase 0–1)

- **`Transport` interface, one implementation** (web). The core speaks messages-in / events-out and knows nothing about HTTP, WebSockets or push. The client's own UX is [web-client-spec.md](web-client-spec.md); what stays in the core is below.
- **Capture coalescing**: inputs arriving within a ~2 s window buffer into one turn ("save these 3 articles" just works). Fed by the share sheet rather than by forwards, unchanged in the core.
- **Structured error UX**: provider/network errors produce one friendly message with a **Retry** affordance and exponential backoff — never a raw stack trace, never a silent hang.
- **Localization** of all bridge-authored strings (`BRIDGE_LOCALE=en|ru`), because the operator here reads Russian; agent output language stays whatever `CLAUDE.md` dictates.

### F2. Sessions (Phase 0–1)

- **Sessions are first-class entities in the core**: `bridge-state/sessions/` holds `{id, title, sdk_session_ids, model, created, last_active, pinned, archived}` plus a display transcript (jsonl of messages, tool events, costs). Nothing is ever erased — starting fresh costs no history, which was the whole complaint about the linear chat model. One running turn per session; a global concurrency cap (default 1) protects the budget.
- SDK `query()` with `resume`; SDK session id persisted per bridge session.
- **Resume fallbacks from day one** (nanoclaw's lesson): on resume failure → start fresh, tell the user in one line, keep the old id in the session's history for manual recovery. No crash-on-oversized-session (Takopi #246 class).
- Turn queue with steering: mid-turn messages offer **Steer** (inject into the running turn), **Queue** (run after), **Cancel current**.
- **Session-size awareness**: the SDK reports usage per result; when a session crosses a configurable context threshold the client shows a hint with a **Start fresh** action — the "context accumulates" foot-gun from [sessions.md](sessions.md) gets a UI instead of a docs paragraph.

### F3. Rendering — *removed*

Markdown → Telegram HTML, fence-aware splitting, shrink-to-fit under 4,096 chars, plain-text fallback: **none of it exists.** The core emits markdown and structured events; the client renders them in a browser at any length ([W-F1](web-client-spec.md#w-f1-chat-pane-with-live-timeline)). The F-number is kept as a gravestone so the deletion is legible in review rather than looking like an oversight — this subsystem was the largest planned test investment in the spec and the acknowledged #1 bug source in every bridge that has one.

### F4. Turn events (Phase 1)

The SDK's tool and text events become a structured timeline, emitted over the transport as they happen:

```
🤔 thinking…
📖 Reading Inbox/2026-07-16.md
✏️ Editing Projects/homelab.md
```

Tool events map to human lines with the target path; text deltas stream into the reply. No status message to edit, so no ≤1-edit/sec throttle and no message-id bookkeeping — the client renders whatever arrives, and Cancel/Steer live in its composer.

### F5. Safety: enforcement, audit, recovery (Phase 1 and 4) — *the differentiator*

- **PreToolUse hook**: deny `Write`/`Edit`/`Bash` whose *resolved* target path escapes `/vault`; enforce trash-instead-of-delete; consume `.agentignore` (improvement-plan D7.L1) as deny patterns. Pattern deny-lists (`CLAUDE_DENIED_COMMANDS`) remain honored for compatibility but stop being the security boundary.
- **Audit log**: every mutating tool call appended to `bridge-state/audit.jsonl` (timestamp, tool, resolved path, session id).
- **Kill-phrase**: a configurable plain-text phrase (default `STOP AGENT`) aborts the running turn and pauses the scheduler until re-enabled.
- **Turn checkpoints + undo + diff** (Phase 4, new capability): before the first mutating tool call of each turn, the bridge snapshots `/vault` into a **shadow git repo** (`GIT_DIR` in `bridge-state/checkpoints.git`, work-tree `/vault` — the vault itself stays free of a visible `.git`).
  - Undo reverts the last turn's changes (with a confirmation showing the file list); diff shows what the last turn touched. Both get a real interface in the client (W-F5) rather than a chat command.
  - Scheduler runs are checkpointed the same way.
  - Retention: prune snapshots older than `BRIDGE_CHECKPOINT_DAYS` (default 14).
  - This does **not** replace off-box backups ([backups.md](backups.md) stands), but it converts the most common failure — "the agent mangled a note and I noticed immediately" — from an incident into a two-tap recovery.

**Hardening set (H1–H6).** What owning the agent loop makes possible beyond the baseline above — the security model shifts from "negotiate with the agent via instructions and fence it from outside" to "every action passes through code we control":

- **H1. Confirmation gates for dangerous operations** (Phase 4). Via the SDK's permission callback: mass renames, moves/edits touching more than `BRIDGE_CONFIRM_FILE_THRESHOLD` files in one turn, or writes into configured sensitive folders pause the turn and ask through the transport — an actionable card, plus a push notification with the answer buttons inline if the app is closed ("Agent wants to move 14 files out of Projects/ — allow?"). Timeout → deny and tell the agent why. Impossible with a headless CLI bridge; the client becomes the interactive approval channel `claude -p` never had.
- **H2. `.agentignore` with real enforcement** (Phase 1, mandatory — improvement-plan D7.L1). One file at the vault root listing private folders, editable from Obsidian on the phone. The bridge expands it into PreToolUse deny rules for `Read`/`Grep`/`Glob`/`Bash` on start and on change — enforced before execution, not requested in CLAUDE.md. Replaces manual tmpfs mounts as the everyday privacy tool (tmpfs stays available for paranoid-tier folders).
- **H3. Per-context permission profiles** (interface designed in Phase 1, enforced with the scheduler in Phase 5). Interactive use gets full vault access; each scheduled task gets its own profile from its YAML header: `morning-digest` — read-only plus write to `Daily/`, `inbox-cleanup` — write only to `Inbox/` and `.trash/`. Shrinks the blast radius precisely where nobody is watching: unattended night runs.
- **H4. Rate limiting and anti-runaway** (Phase 4). `BRIDGE_TURNS_PER_HOUR`, `BRIDGE_MAX_TOOL_CALLS_PER_TURN`, and a mutation circuit-breaker: more than N writes/edits in one turn aborts the turn, checkpoints make it recoverable, and the operator gets pinged. Closes the README's honest "Takopi has no built-in rate limiter" gap.
- **H5. Egress visibility and allowlist** (Phase 5, ships with the url-summarizer). Every `WebFetch`/`WebSearch` URL is written to the audit log (exfiltration via "fetch attacker.com/?data=…" becomes at least visible); `WebFetch` is denied to the main agent and allowed only inside the read-only subagent; optional `BRIDGE_EGRESS_ALLOWLIST` (domain list) turns visibility into blocking without giving up the save-articles feature. The full network-level allowlist (improvement-plan D6.3) remains a separate, stricter compose option.
- **H6. Outbound secret redaction** (Phase 4). Before any reply leaves for a transport, a cheap regex pass masks known secret shapes (`sk-ant-…`, `ghp_…`, private key blocks, API tokens). If the agent quotes a key it stumbled on in a note, it reaches the client masked. Detector patterns shared with the Phase 5 `secret-scan` scheduled task.

### F6. Money: cost visibility and budget guard (Phase 4)

- Per-turn cost from the SDK's `total_cost_usd`; optional per-turn cost display (`💰 $0.0042 · session $0.31`), toggled in settings.
- Usage: today / this week / this month, by interactive vs scheduled, from `spend.json` — a command in the chat pane at Phase 4, a chart at Phase 6 (W-F6).
- **Budget guard**: `BRIDGE_DAILY_BUDGET_USD` / `BRIDGE_MONTHLY_BUDGET_USD`; at 80% the bridge warns (in-app and by push), at 100% it refuses new turns (override button for the operator). Critical when the key is an aggregator key (AI Tunnel) with no Anthropic-console spend limits behind it.
- Works identically on Anthropic direct or any `ANTHROPIC_BASE_URL` provider.

### F7. Custom in-process MCP tools (Phase 5)

- `ask_user`: the agent asks a multiple-choice question, rendered as an actionable card — or as a push notification with the choices as notification actions when the app is closed ("File under Projects or Areas?") — instead of guessing. Timeout → agent proceeds with its best guess and says so.
- `send_file`: the agent pushes a note/export/attachment into the conversation as a downloadable attachment.
- `schedule_task`: the agent writes a *validated* entry into `vault/schedules/` (typed gate: cron expression, model, enabled flag) — natural-language self-scheduling ("remind me Thursday") without freehand file writes.

### F8. Scheduler, digest, heartbeat (Phase 5)

- In-process cron loop sweeping `vault/schedules/*.md` (YAML header: `cron`, `model`, `enabled`; body = prompt). Tasks are markdown **in the vault** → synced, phone-editable in Obsidian.
- Due tasks run as fresh SDK sessions (Haiku default), queued behind interactive turns, never overlapping; results land in their own session and arrive as a Web Push notification; missed-while-busy jobs run late rather than never (RichardAtCT's top issue class, solved by the shared queue).
- Shipped templates, disabled by default: `morning-digest.md`, `inbox-cleanup.md`, `heartbeat.md` ("check inbox and schedules; notify me only if actionable" — the OpenClaw signature), `secret-scan.md` (D7.L3 once gitleaks is in the image).

### F9. Subagents (Phase 5)

- Read-only **`url-summarizer`** `AgentDefinition` (`Read`/`WebFetch` only, no write tools): shared links are fetched and summarized in a context that *cannot* write to the vault or shell out; the main agent files the summary. This is the D6.1 prompt-injection mitigation, ~20 lines here.

### F10. Media and vision (Phase 5)

- **Photos** → passed to the agent as images (Claude vision): whiteboard shots become structured notes, receipts get filed; original saved under `vault/attachments/`. Arrives via the share sheet or a file picker.
- **Documents** (PDF, text files; the limit is now the client's upload size, not a Bot API cap) → saved to `vault/attachments/`, referenced in the turn prompt for processing.

### F11. Skills as markdown → dynamic commands (Phase 5)

- `vault/skills/*.md` (YAML header: `command`, `description`; body = prompt template with `{{args}}`) auto-register on boot and on file change, surfacing as slash-commands in the composer and as tappable chips above it (W-F7).
- Ships with `/capture`, `/append`, `/summarize` — the README roadmap's "safe slash-commands", implemented as user-editable vault files rather than code. Editing a skill from Obsidian on the phone updates the client.

### F12. Memory hookup (Phase 5)

- Templates and `CLAUDE.base.md` instructions from improvement-plan 3.2 (`vault/memory/USER.md`, daily logs); consolidation ships as a `schedules/` task. The bridge itself only needs to *not* get in the way — memory is vault content.

### F13. Ops in the client (Phase 4)

- `/status`: bridge uptime, current session id + approximate context fill, Obsidian Sync state (via the shared volume's sync marker or `ob` status where available), last scheduler runs, today's spend, checkpoint count. Becomes a panel at Phase 6 (W-F6).
- `/model`: show current model; `/model haiku|sonnet|<full-id>` switches for the *next* sessions (persisted). Scheduled tasks keep their per-task `model` header.
- `/help`: generated from the command registry, including vault-defined skills.

## Environment contract

**"The existing `.env` keeps working" is no longer a goal** — it was a Takopi-migration promise, and both Takopi and the transport it configured are being retired. The agent-behavior half of the surface carries over unchanged because it was never about Telegram; the rest is deleted rather than aliased. A config that quietly *accepts* variables for a transport that no longer exists is worse than one that says so.

| Variable | Status |
|---|---|
| `CLAUDE_MODEL`, `CLAUDE_ALLOWED_TOOLS`, `CLAUDE_DENIED_COMMANDS`, `CLAUDE_EXTRA_INSTRUCTIONS`, `VOICE_*`, `OPENAI_API_KEY`, `TZ` | **Honored unchanged** — agent behavior, transport-independent |
| `ANTHROPIC_API_KEY` | Honored (Anthropic direct) |
| `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` | **New**: Anthropic-compatible providers (AI Tunnel etc.); when `ANTHROPIC_AUTH_TOKEN` is set, `ANTHROPIC_API_KEY` is ignored and never forwarded |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | 🗑️ **Gone.** No bot, no chat binding, no claim flow. Present in an env → one startup warning naming this spec, then ignored |
| `TAKOPI_MESSAGE_OVERFLOW`, `TAKOPI_SHOW_RESUME_LINE`, `TAKOPI_SESSION_MODE` | 🗑️ **Gone, not aliased.** Overflow and resume-lines are Telegram artifacts with nothing to alias *to*; `chat` session mode is now the only mode |
| `TAKOPI_DEFAULT_ENGINE`, `TAKOPI_DEFAULT_PROJECT`, `TAKOPI_TOPICS_*`, `CLAUDE_USE_API_BILLING` | 🗑️ Gone, same treatment — single-engine, single-project, SDK-billed by construction |
| `BRIDGE_LOCALE`, `BRIDGE_DAILY_BUDGET_USD`, `BRIDGE_MONTHLY_BUDGET_USD`, `BRIDGE_CHECKPOINT_DAYS`, `BRIDGE_KILL_PHRASE`, `BRIDGE_COST_DISPLAY` | **New**, all with safe defaults |
| `BRIDGE_CONFIRM_FILE_THRESHOLD` (H1), `BRIDGE_TURNS_PER_HOUR`, `BRIDGE_MAX_TOOL_CALLS_PER_TURN` (H4), `BRIDGE_EGRESS_ALLOWLIST` (H5), `BRIDGE_REDACT_SECRETS` (H6, default on) | **New**, hardening set |
| `BRIDGE_WEB_*` (public URL, listen address, proxy-auth headers, push) | **New**, defined in [web-client-spec.md](web-client-spec.md#environment) |
| `BRIDGE_AUDIT_KEEP_DAYS` (default 90), `BRIDGE_UID`/`BRIDGE_GID` (default 1000) | **New**, ops (see [Deployment and operations](#deployment-and-operations)) |

`BRIDGE_REACTIONS` is gone with the emoji-reaction status mechanic — a chat that shows a real timeline does not need 👀 to say "received".

Volumes: same `./vault`; `./bridge-state` replaces `./takopi-state`. **Nothing is worth migrating** — `chat_id` was the only portable artifact and it no longer means anything, so the cutover is a clean start rather than a migration (Takopi's CLI session history was never portable and old conversations were never resumable across it). Both become Coolify persistent volumes at the move. **No secrets are ever written to the state volume** — this closes audit finding S2 by construction, and the Coolify move reinforces it: the env comes from Coolify's UI, so there is no `.env` on disk to leak into a volume backup either.

## Deployment and operations

Everything the bridge must inherit from — or fix in — the surrounding stack ([configuration](configuration.md), [auto-deploy](auto-deploy.md), [operations](operations.md), [backups](backups.md)):

### Deployment target: the home server under Coolify

The stack leaves the "rented VPS plus `docker compose` over SSH" model and moves behind the operator's own infrastructure: the home server, managed by **Coolify**, published through the homelab's tiered wildcard routing as **`agent.app.syntexia.ru`** — tier A, i.e. Authentik + CrowdSec + norobots. **This project ends up owning no VPS at all.**

One word needs disambiguating, because it now means two things. The **edge** — Traefik and Authentik on the homelab's public-facing VPS — stays: it holds the public IP, the wildcard certificate and the SSO for every `*.app` host, and this project is *published through* it, not *deployed to* it. The **project's own VPS** — the box that runs Takopi today — is retired at [cutover](#phased-build-plan). It had one job left that the home server could not do, polling Telegram, and that job no longer exists.

The binding contract is the homelab repo's `docs/guides/app-deploy-requirements.md`; the app-visible consequence is that the bridge runs behind a **double reverse proxy** and sees plain HTTP even though the client sees `https://`:

```
Phone ──HTTPS──▶ edge Traefik ──(TLS terminates, forward-auth)──▶ Netmaker mesh
       ──HTTP──▶ Coolify proxy (Traefik) ──HTTP──▶ bridge container
```

- **One plain-HTTP port on `0.0.0.0`, published nowhere.** Coolify's proxy routes to the container by name; a `localhost` bind would be invisible to it, and a published host port is exactly what the wildcard model removed.
- **Trust the proxy, never redirect.** `X-Forwarded-Proto` / `-Host` / `-For` are the source of truth for absolute URLs and client IPs. The bridge issues no HTTPS redirect of its own — it would see `http` from the proxy and loop forever — and marks cookies `Secure` unconditionally instead of inferring from the request scheme. The `Host` header is validated against `BRIDGE_WEB_PUBLIC_URL`: a mismatch is a deliberate 400, not a silent 200.
- **The domain is env, not code**, and specifically not a build-time constant — the frontend bundle is built in CI before any domain exists. The trap and the runtime-config fix: [web-client-spec — Environment](web-client-spec.md#environment).
- **Health is routing, not cosmetics.** Traefik's Docker provider **does not publish a router for an `unhealthy` container at all** — the failure presents as a flat `404 page not found` from Traefik, not a 502, as though the host never existed. Two consequences. First, the Docker `HEALTHCHECK` must probe **`127.0.0.1`, never `localhost`**: on Alpine/musl `localhost` resolves to `::1` first, where a single-stack IPv4 listener isn't, and the container hangs `unhealthy` forever while the service answers fine. Second, the healthcheck must be *cheap and honest*: it reports the HTTP server's readiness and nothing else. Audit finding R1 — the blocking `/claim` loop that leaves a fresh install `unhealthy` forever — is not fixed here so much as **deleted**, along with the claim flow itself (Authentik replaced it). Behind Traefik that matters more than it did: an unhealthy bridge is an unrouted bridge, including the web UI you would have diagnosed it from.
- **Volumes, or it's gone.** Coolify recreates the container on every deploy, so `/vault` and `bridge-state/` must be declared persistent volumes. `BRIDGE_UID`/`BRIDGE_GID` (default 1000) must line up with the volume's ownership on the host — Coolify-created bind mounts land root-owned, so either pre-`chown` the path or have a root entrypoint fix ownership and drop privileges before exec.
- **Secrets move to the Coolify UI** and stop living in a `.env` rendered by CI from GitHub Secrets. That retires the deploy workflow's `.env` step and `inspect.yml`'s sanitized `.env` dump — Coolify's UI becomes the source of truth. `docker inspect` on the host still exposes them ([security.md](security.md)), and the home box now runs the rest of the homelab alongside the bridge, so that caveat grows: the Docker socket on this host is a credential for the vault too.
- **CI's job ends at the registry.** `build-images.yml` keeps building multi-arch images to GHCR (web bundle included); deployment becomes a Coolify webhook fired *after* the build for the triggering commit finishes, pinned to the immutable `<short-sha>` tag rather than `latest`. This is also the honest fix for audit finding **S1** — the stale-image race disappears once the deploy names an exact image instead of pulling a mutable tag.
- **Tier choice is settled: A, not B.** `*.app` gives the web client Authentik forward-auth for free; the bridge implements no login and validates two headers instead ([web-client-spec — Auth and exposure model](web-client-spec.md#auth-and-exposure-model)). `*.pub` would mean writing the authentication this spec just deleted.

**`CLAUDE.md` assembly moves into the bridge.** Today Takopi's entrypoint regenerates `vault/CLAUDE.md` from the three layers (`CLAUDE.base.md` → `CLAUDE.local.md` → `CLAUDE_EXTRA_INSTRUCTIONS`) once per container start. The bridge takes over the assembly with the same layer order and adds a **file watcher**: editing `CLAUDE.local.md` (from Obsidian on the phone, via sync) regenerates `CLAUDE.md` immediately, and the next *new* session picks it up — the documented "restart the container, then `/new`" ritual reduces to just starting a fresh session; the bridge appends a one-line hint when layers changed mid-session. The SDK is pointed at `/vault/CLAUDE.md` as project memory, preserving today's contract.

**Container parity and health.**
- Same runtime discipline as the existing services: `mem_limit`/`memswap_limit` (1 GB — Node plus the SDK's engine subprocess), CPU cap, json-file log rotation.
- Healthcheck becomes a real HTTP `GET /healthz` (probed at `127.0.0.1` — see above) instead of `pgrep`. It is green as soon as the server accepts connections; a missing provider key or an empty vault is reported through `/status` (F13), not by refusing to be healthy — see above for why an unhealthy container is an invisible one.
- The container runs **non-root** (`BRIDGE_UID`/`BRIDGE_GID`, default 1000): agent-created files stop being root-owned on the host, retiring the recurring `sudo chown -R` chore from [operations.md](operations.md). The SDK subprocess inherits the same UID.

**CI and images.**
- `build-images.yml` gains a `bridge/**` trigger: multi-arch (amd64+arm64) image to GHCR with the same tag scheme; the web frontend bundle is built *inside* the bridge image (static assets served by the web adapter — no CDN, no separate image, no separate deploy).
- The Stage-1 S1 fix is superseded rather than ported: deploying by `<short-sha>` through a post-build Coolify webhook removes the mutable-tag race by construction (see above).

**Installer, Makefile, diagnostics (cutover scope).** `install.sh`/`bootstrap.sh` learn the bridge path (VAPID keygen via `make web-keys`, a preflight for the Coolify preconditions — `http` scheme, Force HTTPS off, proxy secret present on both sides; the Telegram claim-token extraction is deleted); `inspect.yml` loses its `.env` dump (Coolify owns secrets now) and swaps its takopi-internals dump for a bridge-state summary (session count, today's spend, audit tail — secrets stay masked); the [auto-deploy "what persists" table](auto-deploy.md#what-persists-between-deploys) is rewritten around Coolify persistent volumes rather than gitignored host directories.

**State retention.** Everything in `bridge-state/` that grows has a bound: audit log pruned after `BRIDGE_AUDIT_KEEP_DAYS` (default 90), checkpoints after `BRIDGE_CHECKPOINT_DAYS`, `spend.json` compacted to monthly aggregates after a year; display transcripts live as long as their session (deleting/purging an archived session removes its transcript). `/status` shows the state-volume size.

**Backup scope changes.** Unlike `takopi-state/` (disposable), `bridge-state/` now holds data worth keeping: session transcripts, audit trail, spend history, checkpoints. [backups.md](backups.md) gains it as a second backup target next to the vault at cutover — and its off-site story now has to point *away from the house*, where both the vault and every backup-worthy volume live after the move.

**Coexistence notes.** Concurrent vault writes with obsidian-headless (audit R3) remain architecturally unsolved — checkpoints shrink the blast radius but the undo-vs-sync race in [Risks](#risks) stands, and off-box backups remain the boundary. Optional semantic search (improvement-plan 3.3, qmd) stays an orthogonal opt-in compose service; the bridge only allowlists `Bash(qmd *)` when it is present.

## Testing and CI

The no-tests status quo (audit 1.4) does not carry over. Minimum bar per phase:

The Telegram deletion rewrites this section more than any other: the renderer golden tests and splitter property tests — planned as *the largest test investment in the spec*, because rendering is the #1 bug source in every Telegram bridge — are gone with the code they would have covered. Nothing replaces them, because nothing replaces the renderer. The budget moves to the boundaries that remain:

- **Unit tests** for session store + resume fallbacks, budget math, schedule-header parsing, `.agentignore` → deny-pattern expansion (Phase 1 and 4).
- **Safety-hook tests** (Phase 1, the gate for write access): resolved-path escape attempts (`..`, symlinks, absolute paths) are denied; `.agentignore` patterns block `Read`/`Grep`/`Bash`; every mutating call reaches the audit log.
- **E2E against a stub SDK** (Phase 1): boot the bridge with stubbed forward-auth headers and a stub agent runtime; assert turn queue, steering, cancel, error UX, and the auth boundary ([web-client-spec — Testing](web-client-spec.md#testing)).
- **Pinned-SDK CI**: the SDK version is pinned; CI runs against exactly that version; Dependabot proposes bumps that must pass the suite before merge.

## Phased build plan

**One sequence, no parallel tracks** — with a single client there is nothing to run in parallel *with*. The old bridge-core and W-tracks merge; the W-phases keep their content and become phases of this plan (the mapping is repeated in [web-client-spec — Build plan](web-client-spec.md#build-plan)).

| Phase | Content | Exit criteria | Effort |
|---|---|---|---|
| **0 — Spike** | Text-only: HTTP + WS → SDK `query()` + resume → markdown to a minimal chat pane, **behind the `Transport` interface from day one**. Runs on the developer's machine with `BRIDGE_WEB_AUTH_MODE=none`, against the vault read-only. No Coolify, no domain, no Authentik. | Round-trip conversation with continuity across restarts; honest feel-check. **Stop here if it feels worse than what you use today.** | 3–5 days |
| **1 — Deploy + core** | The move: Coolify at `agent.app.syntexia.ru` behind Authentik + the header check. Then multi-session store, turn queue + steering, live turn timeline, error UX, voice, capture coalescing, PreToolUse enforcement + audit + kill-phrase, **`.agentignore` enforcement (H2)**, permission-profile interface (H3 design), localization, E2E suite | Daily driver from the phone browser; write access enabled | ~2 weeks |
| **2 — Sessions** (was W1) | Sidebar, auto-titling, transcript search, per-session model, note-preview drawer | The "walk through your sessions" promise — the reason the client exists | ~1 week |
| **3 — PWA capture** (was W2) | Manifest + service worker, install flow, `share_target`, shortcuts, voice with editable transcript, Web Push, offline capture queue | Share-sheet capture from any Android app; the offline-capture gap closes | ~1 week |
| **4 — Safety & money** | Checkpoints + undo + diff, budget guard + usage + cost display, **confirmation gates (H1)**, **rate limiting + anti-runaway (H4)**, **outbound secret redaction (H6)**, `/status`, `/model`, session-size hints | The two headline differentiators (recoverable vault, hard budget) live, plus the hardening core | ~1.5 weeks |
| **5 — Agentic** | MCP tools (`ask_user`, `send_file`, `schedule_task`), scheduler + digest/heartbeat/cleanup templates with **per-task permission profiles (H3)**, `url-summarizer` subagent + **egress audit/allowlist (H5)**, photos/documents, skills registry, memory templates | The Stage 3 feature set nothing else offers in one place | 1–2 weeks |
| **6 — Workbench** (was W3) | Diff viewer + granular undo, usage/audit/status dashboards, schedules + skills panels, quiet hours | Every panel has something real behind it — which is why this follows 4 and 5 rather than leading them | ~1 week |
| **7 — Cutover** | Bridge becomes the product; **Takopi and the VPS are both retired** — no fallback profile, because a Telegram fallback is what this plan just deleted; Takopi docs to `docs/legacy`; installer/bootstrap/Makefile updates; `inspect.yml` + deploy-pipeline rewrite (SSH deploy → GHCR build + Coolify webhook); docs rewrite (sessions, security, configuration, operations, backups, auto-deploy — incl. `bridge-state` as a backup target, and a forward-auth section in place of the VPS-firewall guidance); CHANGELOG major | One release shipping the bridge; the VPS decommissioned | ~1 week incl. docs |

**Why the move lands in Phase 1 rather than Phase 0.** The spike answers "does this feel right", and it can answer that on localhost with auth off, in an afternoon, against nothing. Everything after it needs the real target, because the domain, the forward-auth headers and the double-proxy hop *are* what the client has to work through. Phase 0 is the last moment this plan can be cheaply abandoned; do not spend the Coolify setup before the feel-check.

**What the VPS still does in the meantime: nothing new.** It keeps running the legacy Takopi stack until Phase 7 retires both. No phase deploys to it, no phase depends on it, and the last thing that needed it — Telegram polling — is no longer in the plan.

Total: **7–9 weeks part-time**, one sequence, with a usable daily driver at the end of Phase 1 (~2.5 weeks in) — on the home server, on the real domain, which is where it stays. Order within phases is flexible; the phase *gates* are not — no write access before the safety hooks exist (Phase 1), no dashboards before there is data behind them (Phase 6), no cutover before the E2E suite is green.

## Risks

Inherited from the [assessment](sdk-bridge-plan.md#risks-and-honest-costs) (maintenance in-house, SDK policy watch, no `_internal`, feature envy, bus factor) — all still apply. New ones introduced by this spec:

- **Checkpoint interplay with Obsidian Sync**: a sync pull can land between snapshot and undo, making the revert clobber a legitimate remote edit. Mitigation: undo shows the file list and warns when files changed *after* the checkpoint; per-file revert selection (W-F5) if it proves common in practice.
- **Budget guard accuracy on aggregators**: `total_cost_usd` reflects Anthropic list prices, not the provider's markup. Mitigation: `BRIDGE_COST_MULTIPLIER` (default 1.0) documented next to the AI Tunnel setup; the guard is a safety net, not accounting.
- **One client, one path to it, no fallback.** This is the sharpest cost of dropping Telegram, and it should be named rather than discovered: the `*.app` tier is a shared SPOF (a Coolify-proxy or mesh-link failure 502s the whole namespace at once — the wildcard model's own documented risk), and there is now no second transport to reach the agent through. Mitigations: Uptime Kuma monitors on the proxy *and* on `agent.app`; the `Transport` seam keeps a re-added adapter an adapter rather than a project; scheduled-task results queue rather than vanish when nothing is reachable. **What blunts it:** an outage costs the *agent*, not the *notes* — the vault is Obsidian-synced and stays fully usable on the phone throughout, which is exactly the property that makes a single-client design defensible here and would not hold for a stack whose data lived in the app.
- **Trusting proxy headers is a placement decision, not a code decision.** The bridge's identity check is only as strong as where the edge injects its secret; get it wrong and anything on the home docker network authenticates as the operator. Spelled out in [web-client-spec — Auth and exposure model](web-client-spec.md#auth-and-exposure-model); the point here is that this is a *deployment* review item, invisible in this repo's code.
- **Coolify preconditions fail silently and misleadingly.** Force HTTPS left on → redirect loop; `localhost` in the `HEALTHCHECK` → permanently `unhealthy` → Traefik serves a flat 404 for a service that works. Both look like application bugs and aren't. The installer preflight and the healthcheck tests exist to keep these out of debugging sessions.
- **Scope creep via F7–F13**: the feature list above is the ceiling, not the floor. Anything not listed needs a removal or a demonstrated need first — same rule as the assessment's non-goals.

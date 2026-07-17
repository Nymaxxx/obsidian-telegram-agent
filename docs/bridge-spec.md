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
- [Deployment and operations](#deployment-and-operations)
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
- Webhook API for third-party integrations
- TTS replies
- Windows host support

> **Scope change (July 2026):** a self-hosted **web client (PWA)** is now in scope as a first-class transport — see [web-client-spec.md](web-client-spec.md). Rationale: Telegram is officially blocked/degraded in Russia since February 2026, which forces the operator onto a VPN — defeating the AI-Tunnel motivation — and its single linear session model erases history that the web client can keep browsable. A public multi-user web SaaS remains a non-goal.

> **Scope change (July 2026, hosting):** the stack moves off the rented VPS and behind the operator's own infrastructure — the **home server under Coolify**, published through the existing tiered wildcard routing as tier A `agent.app.syntexia.ru` (VPS Traefik terminates TLS, Authentik authenticates). The contract this imposes on the code is in [Deployment target](#deployment-target-the-home-server-under-coolify); two consequences reach the plan itself. The web client's entire authentication subsystem is **deleted** (Authentik does it). And Telegram polling from a domestic ISP is expected to degrade, so the web client becomes the primary transport, Telegram becomes best-effort, and the W-track moves ahead of Phases 2–3.

## Architecture

| Decision | Choice | Rationale |
|---|---|---|
| Language | **TypeScript, Node 22** | SDK reference implementation is TS; both donor codebases (linuz90, nanoclaw) are TS; `node:22-alpine` base already in the stack |
| Transports | **Pluggable `Transport` interface**; adapters: Telegram (grammY) and Web PWA ([web-client-spec.md](web-client-spec.md)), each behind a compose profile | Telegram availability in RU is degrading, and hosting at home removes the egress path it currently polls from — the web client becomes the primary transport and the core must not care where messages come from |
| Hosting | **Home server under Coolify**, published as tier A `agent.app.syntexia.ru` behind the VPS Traefik and Authentik (homelab `docs/guides/app-deploy-requirements.md`) | Domain, TLS, CrowdSec and SSO already exist at the edge; the bridge ships one plain-HTTP port, no certificates, and no login code |
| Telegram library | **grammY** | Long-polling, typed, excellent middleware; used by the best donor |
| Agent runtime | **`@anthropic-ai/claude-agent-sdk`**, public API only, version pinned | The whole premise; `_internal` is banned (RichardAtCT's breakage lesson) |
| Process model | Single container, single process: grammY loop + per-chat turn queue + asyncio-style scheduler tick | One thing to deploy, one thing to healthcheck |
| State | `bridge-state/` volume: `chat_id`, `session.json` (per-chat session id + metadata), `spend.json`, `audit.jsonl`, checkpoints git dir | Same pattern as `takopi-state/`, but **no secrets ever written** — tokens live only in process env |
| Provider | Anthropic direct **or any Anthropic-Messages-compatible base URL** via `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` passthrough | AI Tunnel et al. work for both interactive and scheduled runs with zero extra code |
| Rollout | Compose **profile `bridge`** side-by-side with Takopi (separate test bot token) until cutover | Phase 0/1 run risk-free against the same vault |

Component budget (~2.5–3k lines — slightly above the assessment's estimate because of the new safety/money features):

```
bridge/src/
  transport/     Transport interface + telegram adapter (grammY, claim,
                 media handlers, coalescing)                               ~450
  web/           web transport adapter: REST + WS API, proxy-auth check,
                 Web Push (frontend in web-client-spec.md, ~2.5k more)     ~500
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

- **Sessions are first-class entities in the core**, not a per-chat pointer: `bridge-state/sessions/` holds `{id, title, sdk_session_ids, model, created, last_active, pinned, archived}` plus a display transcript (jsonl of messages, tool events, costs). The Telegram transport keeps its familiar linear UX — one *active* session, `/new` switches to a fresh one — but nothing is erased: old sessions stay browsable and resumable from the web client. One running turn per session; a global concurrency cap (default 1) protects the budget.
- SDK `query()` with `resume`; SDK session id persisted per bridge session.
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
  - This does **not** replace off-box backups ([backups.md](backups.md) stands), but it converts the most common failure — "the agent mangled a note and I noticed immediately" — from an incident into a two-tap recovery.

**Hardening set (H1–H6).** What owning the agent loop makes possible beyond the baseline above — the security model shifts from "negotiate with the agent via instructions and fence it from outside" to "every action passes through code we control":

- **H1. Confirmation gates for dangerous operations** (Phase 2). Via the SDK's permission callback: mass renames, moves/edits touching more than `BRIDGE_CONFIRM_FILE_THRESHOLD` files in one turn, or writes into configured sensitive folders pause the turn and ask through the active transport — inline buttons in Telegram, an actionable card + push notification on web ("Agent wants to move 14 files out of Projects/ — allow?"). Timeout → deny and tell the agent why. Impossible with a headless CLI bridge; the chat becomes the interactive approval channel `claude -p` never had.
- **H2. `.agentignore` with real enforcement** (Phase 1, mandatory — improvement-plan D7.L1). One file at the vault root listing private folders, editable from Obsidian on the phone. The bridge expands it into PreToolUse deny rules for `Read`/`Grep`/`Glob`/`Bash` on start and on change — enforced before execution, not requested in CLAUDE.md. Replaces manual tmpfs mounts as the everyday privacy tool (tmpfs stays available for paranoid-tier folders).
- **H3. Per-context permission profiles** (interface designed in Phase 1, enforced with the scheduler in Phase 3). Interactive chat gets full vault access; each scheduled task gets its own profile from its YAML header: `morning-digest` — read-only plus write to `Daily/`, `inbox-cleanup` — write only to `Inbox/` and `.trash/`. Shrinks the blast radius precisely where nobody is watching: unattended night runs.
- **H4. Rate limiting and anti-runaway** (Phase 2). `BRIDGE_TURNS_PER_HOUR`, `BRIDGE_MAX_TOOL_CALLS_PER_TURN`, and a mutation circuit-breaker: more than N writes/edits in one turn aborts the turn, checkpoints make it recoverable, and the operator gets pinged. Closes the README's honest "Takopi has no built-in rate limiter" gap.
- **H5. Egress visibility and allowlist** (Phase 3, ships with the url-summarizer). Every `WebFetch`/`WebSearch` URL is written to the audit log (exfiltration via "fetch attacker.com/?data=…" becomes at least visible); `WebFetch` is denied to the main agent and allowed only inside the read-only subagent; optional `BRIDGE_EGRESS_ALLOWLIST` (domain list) turns visibility into blocking without giving up the save-articles feature. The full network-level allowlist (improvement-plan D6.3) remains a separate, stricter compose option.
- **H6. Outbound secret redaction** (Phase 2). Before any reply leaves for a transport, a cheap regex pass masks known secret shapes (`sk-ant-…`, `ghp_…`, private key blocks, bot tokens). If the agent quotes a key it stumbled on in a note, it reaches the chat masked. Detector patterns shared with the Phase 3 `secret-scan` scheduled task.

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
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` (+claim flow), `CLAUDE_MODEL`, `CLAUDE_ALLOWED_TOOLS`, `CLAUDE_DENIED_COMMANDS`, `CLAUDE_EXTRA_INSTRUCTIONS`, `VOICE_*`, `OPENAI_API_KEY`, `TZ` | **Honored unchanged** |
| `TAKOPI_SESSION_MODE`, `TAKOPI_MESSAGE_OVERFLOW`, `TAKOPI_SHOW_RESUME_LINE` | Honored as legacy aliases of `BRIDGE_*` equivalents |
| `CLAUDE_USE_API_BILLING` | Accepted, becomes a no-op (the SDK always bills via `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN`) |
| `TAKOPI_DEFAULT_ENGINE`, `TAKOPI_DEFAULT_PROJECT`, `TAKOPI_TOPICS_*` | Read and ignored with one startup log line (single-engine, single-project design) |
| `ANTHROPIC_API_KEY` | Honored (Anthropic direct) |
| `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` | **New**: Anthropic-compatible providers (AI Tunnel etc.); when `ANTHROPIC_AUTH_TOKEN` is set, `ANTHROPIC_API_KEY` is ignored and never forwarded |
| `BRIDGE_LOCALE`, `BRIDGE_DAILY_BUDGET_USD`, `BRIDGE_MONTHLY_BUDGET_USD`, `BRIDGE_CHECKPOINT_DAYS`, `BRIDGE_KILL_PHRASE`, `BRIDGE_REACTIONS`, `BRIDGE_COST_FOOTER` | **New**, all with safe defaults |
| `BRIDGE_CONFIRM_FILE_THRESHOLD` (H1), `BRIDGE_TURNS_PER_HOUR`, `BRIDGE_MAX_TOOL_CALLS_PER_TURN` (H4), `BRIDGE_EGRESS_ALLOWLIST` (H5), `BRIDGE_REDACT_SECRETS` (H6, default on) | **New**, hardening set |
| `BRIDGE_WEB_*` (web transport: public URL, listen address, proxy-auth headers, push) | **New**, defined in [web-client-spec.md](web-client-spec.md#environment) |
| `BRIDGE_AUDIT_KEEP_DAYS` (default 90), `BRIDGE_UID`/`BRIDGE_GID` (default 1000) | **New**, ops (see [Deployment and operations](#deployment-and-operations)) |

Volumes: same `./vault`; `./bridge-state` replaces `./takopi-state` (migration note in cutover docs — only `chat_id` is worth carrying over, and the installer does it automatically; Takopi's CLI session history is not portable and old conversations are not resumable across the cutover). Both become Coolify persistent volumes at the move. **No secrets are ever written to the state volume** — this closes audit finding S2 by construction, and the Coolify move reinforces it: the env comes from Coolify's UI, so there is no `.env` on disk to leak into a volume backup either.

## Deployment and operations

Everything the bridge must inherit from — or fix in — the surrounding stack ([configuration](configuration.md), [auto-deploy](auto-deploy.md), [operations](operations.md), [backups](backups.md)):

### Deployment target: the home server under Coolify

The stack leaves the "VPS plus `docker compose` over SSH" model and moves behind the operator's own infrastructure: the home server, managed by **Coolify**, published through the homelab's tiered wildcard routing as **`agent.app.syntexia.ru`** — tier A, i.e. Authentik + CrowdSec + norobots. The binding contract is the homelab repo's `docs/guides/app-deploy-requirements.md`; the app-visible consequence is that the bridge runs behind a **double reverse proxy** and sees plain HTTP even though the client sees `https://`:

```
Phone ──HTTPS──▶ VPS Traefik ──(TLS terminates, forward-auth)──▶ Netmaker mesh
       ──HTTP──▶ Coolify proxy (Traefik) ──HTTP──▶ bridge container
```

- **One plain-HTTP port on `0.0.0.0`, published nowhere.** Coolify's proxy routes to the container by name; a `localhost` bind would be invisible to it, and a published host port is exactly what the wildcard model removed.
- **Trust the proxy, never redirect.** `X-Forwarded-Proto` / `-Host` / `-For` are the source of truth for absolute URLs and client IPs. The bridge issues no HTTPS redirect of its own — it would see `http` from the proxy and loop forever — and marks cookies `Secure` unconditionally instead of inferring from the request scheme. The `Host` header is validated against `BRIDGE_WEB_PUBLIC_URL`: a mismatch is a deliberate 400, not a silent 200.
- **The domain is env, not code**, and specifically not a build-time constant — the frontend bundle is built in CI before any domain exists. The trap and the runtime-config fix: [web-client-spec — Environment](web-client-spec.md#environment).
- **Health is routing, not cosmetics.** Traefik's Docker provider **does not publish a router for an `unhealthy` container at all** — the failure presents as a flat `404 page not found` from Traefik, not a 502, as though the host never existed. Two consequences. First, the Docker `HEALTHCHECK` must probe **`127.0.0.1`, never `localhost`**: on Alpine/musl `localhost` resolves to `::1` first, where a single-stack IPv4 listener isn't, and the container hangs `unhealthy` forever while the service answers fine. Second, the R1-class decision to report **healthy while waiting for `/claim`** stops being a nicety — an unhealthy bridge is an unrouted bridge, including the web UI you would have diagnosed it from.
- **Volumes, or it's gone.** Coolify recreates the container on every deploy, so `/vault` and `bridge-state/` must be declared persistent volumes. `BRIDGE_UID`/`BRIDGE_GID` (default 1000) must line up with the volume's ownership on the host — Coolify-created bind mounts land root-owned, so either pre-`chown` the path or have a root entrypoint fix ownership and drop privileges before exec.
- **Secrets move to the Coolify UI** and stop living in a `.env` rendered by CI from GitHub Secrets. That retires the deploy workflow's `.env` step and `inspect.yml`'s sanitized `.env` dump — Coolify's UI becomes the source of truth. `docker inspect` on the host still exposes them ([security.md](security.md)), and the home box now runs the rest of the homelab alongside the bridge, so that caveat grows: the Docker socket on this host is a credential for the vault too.
- **CI's job ends at the registry.** `build-images.yml` keeps building multi-arch images to GHCR (web bundle included); deployment becomes a Coolify webhook fired *after* the build for the triggering commit finishes, pinned to the immutable `<short-sha>` tag rather than `latest`. This is also the honest fix for audit finding **S1** — the stale-image race disappears once the deploy names an exact image instead of pulling a mutable tag.
- **Tier choice is settled: A, not B.** `*.app` gives the web client Authentik forward-auth for free; the bridge implements no login and validates two headers instead ([web-client-spec — Auth and exposure model](web-client-spec.md#auth-and-exposure-model)). `*.pub` would mean writing the authentication this spec just deleted.

**`CLAUDE.md` assembly moves into the bridge.** Today Takopi's entrypoint regenerates `vault/CLAUDE.md` from the three layers (`CLAUDE.base.md` → `CLAUDE.local.md` → `CLAUDE_EXTRA_INSTRUCTIONS`) once per container start. The bridge takes over the assembly with the same layer order and adds a **file watcher**: editing `CLAUDE.local.md` (from Obsidian on the phone, via sync) regenerates `CLAUDE.md` immediately, and the next *new* session picks it up — the documented "restart the container, then `/new`" ritual reduces to just starting a fresh session; the bridge appends a one-line hint when layers changed mid-session. The SDK is pointed at `/vault/CLAUDE.md` as project memory, preserving today's contract.

**Container parity and health.**
- Same runtime discipline as the existing services: `mem_limit`/`memswap_limit` (1 GB — Node plus the SDK's engine subprocess), CPU cap, json-file log rotation.
- Healthcheck becomes a real HTTP `GET /healthz` (probed at `127.0.0.1` — see above) instead of `pgrep`, and it reports **healthy while waiting for `/claim`** (with a `waiting_for_claim` status field), fixing the R1-class cosmetics where a perfectly fine fresh install shows `unhealthy`. `/status` (F13) exposes the same data in chat.
- The container runs **non-root** (`BRIDGE_UID`/`BRIDGE_GID`, default 1000): agent-created files stop being root-owned on the host, retiring the recurring `sudo chown -R` chore from [operations.md](operations.md). The SDK subprocess inherits the same UID.

**CI and images.**
- `build-images.yml` gains a `bridge/**` trigger: multi-arch (amd64+arm64) image to GHCR with the same tag scheme; the web frontend bundle is built *inside* the bridge image (static assets served by the web adapter — no CDN, no separate image, no separate deploy).
- The Stage-1 S1 fix is superseded rather than ported: deploying by `<short-sha>` through a post-build Coolify webhook removes the mutable-tag race by construction (see above).

**Installer, Makefile, diagnostics (Phase 4 scope).** `install.sh`/`bootstrap.sh` learn the bridge path (claim auto-extraction, VAPID keygen via `make web-keys`, a preflight for the Coolify preconditions — `http` scheme, Force HTTPS off, proxy secret present on both sides); `inspect.yml` loses its `.env` dump (Coolify owns secrets now) and swaps its takopi-internals dump for a bridge-state summary (session count, today's spend, audit tail — secrets stay masked); the [auto-deploy "what persists" table](auto-deploy.md#what-persists-between-deploys) is rewritten around Coolify persistent volumes rather than gitignored host directories.

**State retention.** Everything in `bridge-state/` that grows has a bound: audit log pruned after `BRIDGE_AUDIT_KEEP_DAYS` (default 90), checkpoints after `BRIDGE_CHECKPOINT_DAYS`, `spend.json` compacted to monthly aggregates after a year; display transcripts live as long as their session (deleting/purging an archived session removes its transcript). `/status` shows the state-volume size.

**Backup scope changes.** Unlike `takopi-state/` (disposable), `bridge-state/` now holds data worth keeping: session transcripts, audit trail, spend history, checkpoints. [backups.md](backups.md) gains it as a second backup target next to the vault at cutover — and its off-site story now has to point *away from the house*, where both the vault and every backup-worthy volume live after the move.

**Coexistence notes.** Concurrent vault writes with obsidian-headless (audit R3) remain architecturally unsolved — checkpoints shrink the blast radius but the `/undo`-vs-sync race in [Risks](#risks) stands, and off-box backups remain the boundary. Optional semantic search (improvement-plan 3.3, qmd) stays an orthogonal opt-in compose service; the bridge only allowlists `Bash(qmd *)` when it is present.

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
| **0 — Spike** | Text-only: polling → SDK `query()` + resume → HTML render/split → reply, **behind the `Transport` interface from day one**. Runs as compose profile `bridge` with a separate test bot token, side-by-side with Takopi on the same vault (read-only allowlist). Renderer/splitter tests. | Round-trip conversation with continuity across restarts; honest feel-check vs Takopi. **Stop here if it feels worse.** | 2–4 days |
| **1 — Parity+** | Claim binding, `/new` `/cancel`, multi-session store, turn queue + steering buttons, streaming status, reactions, error UX, voice, forward coalescing, backlog processing, PreToolUse enforcement + audit + kill-phrase, **`.agentignore` enforcement (H2)**, permission-profile interface (H3 design), env compatibility, localization, E2E suite | Daily driver replacing the used Takopi subset; existing `.env` works unchanged; write access enabled | 1–2 weeks |
| **2 — Safety & money** | Checkpoints + `/undo` + `/diff`, budget guard + `/usage` + cost footer, **confirmation gates (H1)**, **rate limiting + anti-runaway (H4)**, **outbound secret redaction (H6)**, `/status`, `/model`, session-size hints, media groups, `/reasoning` | The two headline differentiators (recoverable vault, hard budget) live, plus the hardening core | ~1.5 weeks |
| **3 — Agentic** | MCP tools (`ask_user`, `send_file`, `schedule_task`), scheduler + digest/heartbeat/cleanup templates with **per-task permission profiles (H3)**, `url-summarizer` subagent + **egress audit/allowlist (H5)**, photos/documents, skills registry, memory templates | The Stage 3 feature set nothing else offers in one place | 1–2 weeks |
| **W — Web client** | Starts after Phase 1 and **runs ahead of Phases 2–3**; W0 carries the move to home Coolify; phases W0–W3 defined in [web-client-spec.md](web-client-spec.md) | Android PWA daily driver: capture via share sheet, browsable sessions, diff workbench | 3–4 weeks |
| **4 — Cutover** | Bridge becomes compose default; Takopi demoted to a fallback profile for one release, then `docs/legacy`; state migration; installer/bootstrap/Makefile updates; `inspect.yml` + deploy-pipeline rewrite (SSH deploy → GHCR build + Coolify webhook); docs rewrite (sessions, security, configuration, operations, backups, auto-deploy — incl. `bridge-state` as a backup target, and a forward-auth section in place of the VPS-firewall guidance); CHANGELOG major | One release shipping both; the next shipping bridge-only | ~1 week incl. docs |

**Ordering after the hosting decision: 0 → 1 → W0 → W1 → W2 → 2 → W3 → 3 → 4.** The deployment-target switch lands with **W0**, because the web adapter's domain, forward-auth headers and double-proxy hop are precisely what it has to be tested against. Phases 0–1 develop against the current VPS deployment, where Telegram long-polling still works and the spike is cheapest to feel out. After the move, polling `api.telegram.org` from a domestic ISP is expected to degrade: the Telegram transport becomes **best-effort**, stops being a gate for anything, and the daily-driver bar moves from Phase 1 to W1. Nothing in Phases 2–4 depends on Telegram — which is exactly what the `Transport` interface was bought for, sooner than expected.

Total: **6–8 weeks part-time** for the bridge core plus the web track, with a usable daily driver at Phase 1 (~2 weeks in, still on the VPS) and again at W1 (on the home server, transport-independent). Order within phases is flexible; the phase *gates* are not — no write access before the safety hooks exist, no cutover before the E2E suite is green.

## Risks

Inherited from the [assessment](sdk-bridge-plan.md#risks-and-honest-costs) (maintenance in-house, SDK policy watch, no `_internal`, feature envy, bus factor) — all still apply. New ones introduced by this spec:

- **Checkpoint interplay with Obsidian Sync**: a sync pull can land between snapshot and `/undo`, making the revert clobber a legitimate remote edit. Mitigation: `/undo` shows the file list and warns when files changed *after* the checkpoint; per-file revert selection if it proves common in practice.
- **Budget guard accuracy on aggregators**: `total_cost_usd` reflects Anthropic list prices, not the provider's markup. Mitigation: `BRIDGE_COST_MULTIPLIER` (default 1.0) documented next to the AI Tunnel setup; the guard is a safety net, not accounting.
- **The `*.app` tier is a shared SPOF, and the fallback transport is the one being demoted.** A Coolify-proxy or mesh-link failure 502s the whole namespace at once (the wildcard model's own documented risk), and a Telegram adapter that no longer polls from home cannot cover for it — a stack with two transports can still have one outage that takes both. Mitigations: Uptime Kuma monitors on the proxy *and* on `agent.app`; keep the Telegram adapter shipped and configurable so a VPN-assisted fallback stays one env change away rather than a rebuild; scheduled-task results queue rather than vanish when no transport is reachable.
- **Trusting proxy headers is a placement decision, not a code decision.** The bridge's identity check is only as strong as where the edge injects its secret; get it wrong and anything on the home docker network authenticates as the operator. Spelled out in [web-client-spec — Auth and exposure model](web-client-spec.md#auth-and-exposure-model); the point here is that this is a *deployment* review item, invisible in this repo's code.
- **Coolify preconditions fail silently and misleadingly.** Force HTTPS left on → redirect loop; `localhost` in the `HEALTHCHECK` → permanently `unhealthy` → Traefik serves a flat 404 for a service that works. Both look like application bugs and aren't. The installer preflight and the healthcheck tests exist to keep these out of debugging sessions.
- **Scope creep via F7–F13**: the feature list above is the ceiling, not the floor. Anything not listed needs a removal or a demonstrated need first — same rule as the assessment's non-goals.

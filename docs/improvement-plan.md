---
title: "Audit and improvement plan — Obsidian Telegram Agent"
description: "July 2026 in-depth audit of the codebase and docs, ecosystem review (Takopi, Obsidian, transcription, competitors, Claude Agent SDK), and a staged improvement plan with options, trade-offs, and complexity estimates."
---

# Audit and improvement plan (July 2026)

A point-in-time audit of the project (v0.3.0, commit `2a00317`) plus a review of what appeared in the ecosystem through mid-2026, distilled into a staged plan. Every improvement lists its options with pros, cons, and an implementation-complexity estimate so items can be picked up independently in future sessions or PRs.

**Complexity scale used throughout:**

| Rating | Meaning |
|---|---|
| **S** | Small — under ~2 hours, one file or a config change, trivially reviewable |
| **M** | Medium — half a day to a day, several files, needs testing |
| **L** | Large — multiple days, new component or architectural change |
| **XL** | Project-sized — a rewrite or a new subsystem, needs its own design pass |

Contents:

- [Part 1 — Audit findings](#part-1--audit-findings)
- [Part 2 — Ecosystem review](#part-2--ecosystem-review-july-2026)
- [Part 3 — Improvement plan](#part-3--improvement-plan)
- [Part 4 — Strategic options](#part-4--strategic-options)
- [Part 5 — Suggested sequencing](#part-5--suggested-sequencing)

---

## Part 1 — Audit findings

### 1.1 Security

#### S1. CI race: deploy can ship a stale image (critical)

`deploy.yml` and `build-images.yml` both trigger on `push` to `main`. A commit touching `takopi/**` or `obsidian-headless/**` starts both workflows in parallel. The deploy job runs `docker compose pull` on the mutable `:latest` tag while the build job is still rebuilding and pushing it — so the VPS deploys the *previous* image, and the new one only lands on the *next* deploy. There is no `workflow_run` / `needs:` chain between the workflows.

- Impact: silent one-deploy lag for any image change; a security fix in the entrypoint would not actually reach the VPS when the deploy workflow reports success.
- Where: `.github/workflows/deploy.yml` (push trigger + `docker compose pull`), `.github/workflows/build-images.yml` (same push trigger).

#### S2. Secrets in plaintext on a persistent host volume (critical)

`takopi/entrypoint.sh` renders `bot_token = "..."` (line 188) and `voice_transcription_api_key = "..."` (lines 201–203) into `~/.takopi/takopi.toml`, where `HOME=/state` is the `./takopi-state` host volume. Consequences:

- Any backup of the project directory silently captures the Telegram bot token and API keys.
- `docs/security.md` lists `docker inspect` and `obsidian-state/` as secret-bearing surfaces but **not** this file, so a user following the docs' hardening checklist still leaves it exposed.
- The file is written with default permissions (no `chmod 600`).

#### S3. Deny-list bypasses using plain shell syntax (critical to document, partially fixable)

`docs/security.md` and `vault/CLAUDE.base.md` honestly acknowledge the `python -c "os.remove(...)"` class of bypass. But simpler holes exist while `Bash` is allowed, and they are neither blocked nor documented:

| Bypass | Effect | Blockable by pattern? |
|---|---|---|
| `> note.md` / `: > note.md` | truncates a file to zero bytes | No — redirection isn't a command |
| `mv other.md note.md` | clobbers an existing note (`mv` is allowlisted in `CLAUDE.base.md`) | Only by denying `mv` entirely (breaks legitimate moves) |
| `git rm`, `git reset --hard`, `git clean -f` | deletes/reverts tracked files | Yes — addable to deny-list |
| `/bin/rm`, `/usr/bin/rm` | prefix patterns like `Bash(rm *)` don't match absolute paths | Yes — addable |
| `tee note.md` | overwrites a file | Yes — addable (rarely needed legitimately) |
| `sed -i`, `sort -o file file` | in-place rewrites | Partially; `sed -i` is arguably legitimate agent behavior |

The real boundary is (and will remain) **backups** — but the docs should say so explicitly and the cheap wins (`git rm`, absolute paths, `tee`) should be added to the default deny-list.

#### S4. Prompt injection has no technical mitigation

`docs/security.md` describes the risk honestly, but the only defense is instruction text in `CLAUDE.base.md`. Meanwhile the default behavior actively encourages fetching arbitrary forwarded URLs (`CLAUDE.base.md` "save articles" flow) with `WebFetch` allowlisted. A malicious page can instruct the agent to exfiltrate note contents (e.g. via a crafted URL fetch) or mangle the vault. Mitigation options are covered in [Part 4, D6](#d6-prompt-injection-hardening).

#### S5. Supply-chain hygiene in CI

- Third-party actions pinned by tag, not commit SHA: `appleboy/ssh-action@v1` (`deploy.yml`, `inspect.yml`), `ludeeus/action-shellcheck@2.0.0`, `hadolint/hadolint-action@v3.1.0`, plus `actions/checkout@v4`, `docker/*@v3/v5`. A hijacked tag executes arbitrary code with repo secrets (the deploy SSH key!).
- `ci.yml` installs actionlint via unpinned `bash <(curl -fsSL .../main/...)` — a moving target executed in CI.
- Base images not pinned by digest (`python:3.13-slim`, `node:22-alpine`): a rebuild can silently pull a different runtime. App-level pins exist; runtime-level ones don't.
- No `.github/dependabot.yml`, so all of the above rots silently. No `SECURITY.md` vulnerability-disclosure policy (there is `docs/security.md`, but that's operator guidance, not a disclosure policy).

### 1.2 Reliability

#### R1. Blocking `/claim` loop keeps the container "unhealthy" indefinitely

`detect_chat_id` in `takopi/entrypoint.sh` polls `getUpdates` in a `while true` loop until a chat binds. Until then the takopi binary hasn't started, so the healthcheck (`pgrep -f /root/.local/bin/takopi`, `docker-compose.yml`) fails after `start_period` 60s. With no autoheal configured this is cosmetic, but it misleads (`docker ps` shows unhealthy on a perfectly fine fresh install waiting for `/claim`), and the loop has no timeout or backoff cap.

#### R2. `OBSIDIAN_AUTOSTART_SYNC=true` with unconfigured sync → permanent unhealthy

`obsidian-headless/entrypoint.sh` falls back to `sleep infinity` when sync isn't configured, while the mode-aware healthcheck expects a `pgrep -f 'ob sync'` process. The state is documented in `docs/operations.md`, but the healthcheck cannot distinguish "not configured yet" from "sync crashed" — both look identical to monitoring.

#### R3. No file-level coordination between takopi and obsidian-headless

Both containers share `./vault` with no locking; a sync pull mid-agent-edit can produce conflicted or interleaved writes. Documented as an edge case in `docs/backups.md`. Not realistically solvable at this layer (Obsidian Sync has no lock protocol) — the mitigation is backups, and the docs already say so. Listed here for completeness, no action proposed.

#### R4. `deploy.yml` uses `git reset --hard origin/main` on the VPS

Correct for tracked files (vault and `.env` are gitignored), but it silently destroys any local hotfix an operator made on the VPS. At minimum worth a warning line in `docs/auto-deploy.md`.

### 1.3 Documentation drift

| # | Issue | Where |
|---|---|---|
| D1 | CHANGELOG claims the README "states the default is **Sonnet**" — actual default everywhere is `claude-haiku-4-5` | `CHANGELOG.md` `[0.3.0]` entry vs `docker-compose.yml`, `.env.example`, `scripts/install.sh`, `.github/workflows/deploy.yml`, `docs/configuration.md` |
| D2 | Duplicate `### Changed` heading inside `[0.3.0]` — violates Keep a Changelog (one section per category per release) | `CHANGELOG.md` |
| D3 | Repo layout lists 2 workflows; there are 4 (`ci`, `deploy`, `build-images`, `inspect`); `docs/auto-deploy.md` correctly says "four workflows" — internal contradiction. Layout also omits `docker-compose.dev.yml`, `CONTRIBUTING.md`, `LICENSE`, `_config.yml` | `docs/configuration.md` |
| D4 | README links `vault/CLAUDE.local.md`, which is gitignored and absent → 404 on GitHub. Should link `templates/CLAUDE.local.md.example` | `README.md` ("Tailor the agent" section) |
| D5 | README says bootstrap is "~120 lines"; actual `scripts/bootstrap.sh` is 143 lines | `README.md` |
| D6 | `LICENSE` says 2025; releases are dated 2026 | `LICENSE` |

### 1.4 DX / CI gaps

- **No tests at all.** CI is lint-only (shellcheck, hadolint, actionlint, `docker compose config`). Yet `scripts/install.sh` and `takopi/entrypoint.sh` carry non-trivial logic: JSON validation of `CLAUDE_ALLOWED_TOOLS`/`CLAUDE_DENIED_COMMANDS`, CRLF normalization for Windows SSH input, the three-layer `CLAUDE.md` assembly, `/claim` token parsing, `ob sync-list-remote` output parsing. All of it is regression-prone and none of it is covered.
- CI validates `docker compose config` for the prod file but not the dev override combination (`-f docker-compose.yml -f docker-compose.dev.yml config`).
- No `CODEOWNERS`, no `.dockerignore` (low impact — build contexts are tiny).

### 1.5 What is already good (keep as-is)

- App versions pinned with an explicit "bump deliberately" rationale (takopi 0.22.3, Claude Code 2.1.128, obsidian-headless 0.0.8).
- Honest two-layer permission model: permissive allowlist, deny-list as the real boundary, and docs that say so.
- Fail-fast JSON validation of tool env vars before writing `settings.json` — prevents container restart-loops on a typo.
- The `/claim` chat-binding flow (random token; an attacker needs both the bot token *and* container logs) with self-healing of an empty chat-id file.
- Resource limits with `memswap_limit == mem_limit` (predictable OOM), log rotation on both services, mode-aware healthcheck with correct `$${VAR}` escaping.
- Script hygiene: `set -euo pipefail` everywhere, CRLF handling, injection-safe exec, idempotent bootstrap that prints the SHA and warns on non-fast-forward.
- Mandatory `BACKUP_ACKNOWLEDGED=1` in non-interactive installs; prominent data-loss warning in README.
- `inspect.yml` masks secrets and truncates `CLAUDE_EXTRA_INSTRUCTIONS` before echoing.
- `.gitattributes` forcing LF on shell/Dockerfile/YAML; proper CHANGELOG (Keep a Changelog), CONTRIBUTING, issue templates, tmpfs-based hard vault isolation option.

---

## Part 2 — Ecosystem review (July 2026)

### 2.1 Takopi and Telegram bridges

**Takopi is dormant.** Last release v0.23.4 (May 25, 2026); no commits on master since, 27 open PRs accumulating (vs. only 12 open issues — historically healthy triage that stopped). Development was extremely rapid Dec 2025 → May 2026 (40+ releases), then a hard stop. Not archived; ecosystem plugins exist; it works fine today. Features gained between this repo's pin (0.22.3) and 0.23.4: steering/cancel buttons for queued continuations, `/reasoning` for Claude, `codex app-server` default.

Maintained alternatives, if the bridge ever needs replacing:

| Bridge | Stars | Status | Notable features vs. Takopi |
|---|---|---|---|
| [RichardAtCT/claude-code-telegram](https://github.com/RichardAtCT/claude-code-telegram) | ~2.7k | Active (v1.6.0 Mar 2026) | Built on Claude **Agent SDK** (not CLI shelling); cron **job scheduler**; webhook API server; file/image upload with archive extraction; audit log; per-user auth |
| [terranc/claude-telegram-bot-bridge](https://github.com/terranc/claude-telegram-bot-bridge) | ~124 | Active (v0.10.1 May 2026) | Lightweight; numbered options → inline buttons; session browse/resume/revert; confirmation gate for out-of-project file access |
| **Claude Code Channels** (official Anthropic plugin) | — | Launched Mar 2026 | First-party Telegram/Discord bridge into a *running* Claude Code session; pairing-code auth; 50 MB attachments. Limitations: session must stay alive (messages lost when it's down), no history, needs Bun |
| [slopus/happy](https://github.com/slopus/happy) | ~22.6k | Very active | Not Telegram — native iOS/Android/web client for Claude Code with E2E encryption, push, permission prompts in-app, session handoff. Strongest overall "control Claude Code from the phone" option |

Also notable: the category leader **OpenClaw** (~380k stars) and its "small auditable" counterpart **nanoclaw** (~30k, built directly on the Claude Agent SDK, one Docker container per agent group) — see [2.5](#25-competitor-features-worth-borrowing).

### 2.2 Obsidian ecosystem

- **obsidian-headless moved fast**: this repo pins 0.0.8; upstream is 0.0.13 (July 11, 2026), actively iterated (Publish operations, remote vault creation, sync improvements). Requires Node 22+ — the current `node:22-alpine` base is fine.
- **Obsidian Bases** (1.9+, GA since ~Aug 2025): notes-as-database views. `.base` files are **plain YAML** (`filters`, `formulas`, `properties`, `views`), officially documented and embeddable in markdown code blocks — an agent can create and edit them programmatically. All underlying data stays in frontmatter, i.e. already in the agent's reach.
- **Frontmatter breaking change** (1.9): singular `tag`/`alias`/`cssclass` keys were **removed**. An agent writing frontmatter must use plural list forms `tags`/`aliases`/`cssclasses`. The current `CLAUDE.base.md` does not mention this.
- **Official Obsidian CLI** (1.12, Feb 2026): 100+ commands, but it remote-controls the running desktop app (launches Electron if absent) — not usable on a headless VPS today. Watch for a standalone mode.
- **MCP servers for Obsidian**: mature options exist (cyanheads/obsidian-mcp-server for REST-API mode, bitbonsai/mcpvault for direct file mode), but community consensus is that direct filesystem access — what this project already does via Claude Code's own tools — covers ~90% of real use. No integration urgency. There is **no official Obsidian MCP server** (a claim circulating in directories is misattributed).
- **Semantic search over the vault on small CPUs became practical** in 2026: [tobi/qmd](https://github.com/tobi/qmd) (SQLite FTS5 + sqlite-vec CLI), [basicmachines-co/basic-memory](https://github.com/basicmachines-co/basic-memory) (MCP knowledge-graph over plain markdown), and several MiniLM-ONNX-based tools all run in <1 GB RAM on 1–2 vCPU. Heavyweights are out: Khoj needs 4–8 GB and is losing momentum; Smart Connections runs only inside the Electron app.

### 2.3 Voice transcription

Current default: OpenAI `gpt-4o-mini-transcribe` at ~$0.003/min (~$0.18/hr). What changed:

| Option | Price | RU quality | Fit |
|---|---|---|---|
| **Groq `whisper-large-v3-turbo`** | **~$0.04/hr** (~$0.00067/min); free tier ≈2,000 req/day | Good (large-v3 class, ~8% WER) | Best API option: ~4× cheaper, free tier covers a personal bot entirely, accepts Telegram ogg/opus natively, OpenAI-compatible API → works with takopi's existing `voice_transcription_base_url` |
| Mistral **Voxtral Mini Transcribe V2** | $0.003/min | ~4% WER (vendor claim), 13 languages incl. RU | Same price as current with better claimed accuracy; OpenAI-compat endpoint |
| OpenAI `gpt-4o-mini-transcribe` (current) | $0.003/min | Good | Fine; just not the cheapest anymore |
| ElevenLabs Scribe v2 | $0.22/hr | Excellent tier | Priciest; overkill here |
| **Local: GigaAM v3 ONNX INT8** (+ whisper.cpp base for EN) | $0 | **~3.3% WER RU** — best-in-class, faster than realtime on 2 vCPU, ~250 MB | Only fully-local option that's both good and feasible on this hardware; needs a small OpenAI-compatible sidecar service |
| Local: whisper.cpp large/turbo, faster-whisper, Voxtral 3–4B GGUF | $0 | good | **Not feasible** at acceptable speed on 1–2 vCPU; also CTranslate2 (faster-whisper's engine) is unmaintained |

### 2.4 Claude platform

- **Models** (verified pricing, mid-2026): Haiku 4.5 `claude-haiku-4-5` $1/$5 per MTok (200K ctx) — the current default and still the right budget choice. Sonnet 5 `claude-sonnet-5` $3/$15 with **intro pricing $2/$10 until Aug 31, 2026** (1M ctx). Opus 4.8 $5/$25. Fable/Mythos 5 ($10/$50, always-on thinking) — not economical for a personal vault bot.
- **Prompt caching** (reads ~0.1× input price) matters for this stack: the assembled `CLAUDE.md` + system prompt is re-sent every message. Takopi/Claude Code handle this internally, but model choice and instruction size still drive cost.
- **Claude Agent SDK** (`claude-agent-sdk` on PyPI, `@anthropic-ai/claude-agent-sdk` on npm): Claude Code packaged as a library — the full harness (tools, sessions, hooks, subagents, permission modes, MCP, streaming) programmatically. Anthropic's recommended way to embed Claude Code in a bot, and the natural long-term replacement for shelling out to the CLI. RichardAtCT's bridge and nanoclaw are both built on it.
- **Claude Code hooks** (PreToolUse/PostToolUse/etc. in `settings.json`) can enforce vault rules *in the harness* rather than by instruction — e.g. block writes outside `/vault`, log every file modification. Available today without the SDK.
- **Managed Agents** (Anthropic-hosted agent loop + sandbox, beta): scheduled deployments (cron), memory stores, SSE event streams. Would eliminate the VPS entirely, but the vault would have to live in Anthropic's container — awkward with Obsidian Sync headless. Watch, don't adopt.

### 2.5 Competitor features worth borrowing

The personal-agent category exploded in 2026 (OpenClaw ~380k★, nanoclaw ~30k★, agent-second-brain — a direct Telegram→Claude Code→Obsidian analogue, obsidian-second-brain — a 44-command vault-maintenance skill pack). Feature convergence across the winners, ranked by recurrence and cheapness to adopt here:

1. **Morning digest / daily briefing** — scheduled job reads yesterday's notes + open tasks, writes a daily note, sends a Telegram summary.
2. **Nightly inbox auto-filing** — everything lands in `Inbox/`; a nightly pass tags, wikilinks, files, and extracts tasks.
3. **Heartbeat** (OpenClaw's signature) — a periodic agent turn with a checklist ("check inbox/schedules; message me only if actionable"). Most of why these agents feel "alive".
4. **Natural-language self-scheduling** — "remind me Thursday" → the agent writes its own entry in a `schedules/` folder that the scheduler sweeps.
5. **Structured memory in the vault** — `USER.md` (facts/preferences), `memory/YYYY-MM-DD.md` daily logs, periodic consolidation with decay (agent-second-brain uses Ebbinghaus-style tiers).
6. **Skills as markdown in the vault** — user-editable workflow files the agent loads on demand; cheap extensibility without code.
7. **Kill-phrase / emergency stop** — a plain-text phrase that halts the agent; security posture as a feature.

Notably, OpenClaw's widely-reported security incidents (exposed gateways, prompt-injection with full shell) make this project's sandboxed, deny-listed, single-chat design a genuine differentiator. The right move is adopting the *features* above while keeping the *containment*.

---

## Part 3 — Improvement plan

Each item: what to do, options considered, pros/cons, complexity.

### Stage 1 — audit fixes

#### 1.1 Fix the CI deploy race (fixes S1)

| Option | Pros | Cons | Complexity |
|---|---|---|---|
| **A (recommended): `workflow_run` chain** — deploy's push-trigger becomes "after `build-images.yml` completes successfully on main"; keep `workflow_dispatch` for manual deploys | Correct ordering guaranteed; no infra change; docs-only commits can keep a fast path | `workflow_run` UX is worse (runs appear detached from the commit); needs care to keep deploys for docs-only commits that don't build images | **S–M** |
| B: deploy by digest — build job outputs the image digest; deploy pins it | Immutable, reproducible deploys; audit trail | More moving parts (artifact/output passing between workflows); `.env`-based `IMAGE_TAG` interplay | M |
| C: single workflow with `needs:` (merge build+deploy) | Simplest mental model | Loses independent manual deploy/build triggers; longer critical path | S |

#### 1.2 Extend the default deny-list (partially fixes S3)

Add to `docker-compose.yml` and `.env.example`: `Bash(git rm *)`, `Bash(git reset --hard*)`, `Bash(git clean *)`, `Bash(/bin/rm *)`, `Bash(/usr/bin/rm *)`, `Bash(tee *)`.

- Pros: closes the cheap, unambiguous holes; zero UX cost (agents rarely legitimately need these).
- Cons: still not airtight (`> file`, `mv` clobber remain by construction); slightly longer env var.
- Also: rewrite the `docs/security.md` bypass section to enumerate the full table from S3 and state plainly that **backups are the real boundary**.
- Complexity: **S**.

#### 1.3 Document and harden secret storage (fixes S2)

- `chmod 600` the rendered `takopi.toml` in `takopi/entrypoint.sh` (one line).
- Add a `docs/security.md` subsection: what lives in `takopi-state/`, that backups of the project dir include it, and how to exclude it.
- Optional hardening beyond that (docker secrets, env-only injection) is disproportionate for a single-user stack — takopi reads the token from its TOML, so removing it entirely means patching takopi. Not worth it now; revisit under strategic option [D1](#d1-bridge-strategy).
- Complexity: **S**.

#### 1.4 Fix documentation drift (fixes D1–D6)

CHANGELOG duplicate heading + wrong Sonnet claim; four-workflow repo layout in `docs/configuration.md`; README link → `templates/CLAUDE.local.md.example`; "~120 lines" → actual count; LICENSE year. Pure text edits.

- Complexity: **S**.

#### 1.5 Bump pins and add supply-chain guardrails (fixes S5, ecosystem drift)

- obsidian-headless 0.0.8 → 0.0.13 (verify sync + auth flows manually after — upstream moves fast and is pre-1.0, so treat as a **deliberate, tested** bump).
- takopi 0.22.3 → 0.23.4 (final dormant release; gains steering/cancel buttons, `/reasoning`).
- Claude Code 2.1.128 → current.
- Pin all third-party actions by commit SHA; replace `curl | bash` actionlint with a pinned release download.
- Add `.github/dependabot.yml` (ecosystems: `github-actions`, `docker`) and a root `SECURITY.md` (disclosure contact + supported versions).
- Pros: closes the highest-leverage supply-chain gaps for a repo whose CI holds a VPS SSH key. Cons: SHA pins are uglier to read (dependabot mitigates); pre-1.0 headless bump carries regression risk (mitigated by manual verification + easy rollback via `IMAGE_TAG`).
- Complexity: **M** (mostly verification time, not code).

#### 1.6 Add a test suite (fixes the DX gap)

| Option | Pros | Cons | Complexity |
|---|---|---|---|
| **A (recommended): bats-core for shell functions** — extract testable functions (JSON validation, CRLF normalization, CLAUDE.md assembly, claim-token parsing) and cover them; run in CI | Catches real regressions in the riskiest code; fast; no infra | Requires light refactoring of scripts into sourceable functions | **M** |
| B: smoke test — boot the stack in CI with fake tokens, assert healthchecks/config rendering | End-to-end confidence | Slow CI; fake-token behavior (claim loop) needs special-casing; flaky-prone | M |
| C: both | Best coverage | Most work | M+M |

Start with A; add B once A is stable. Also add the dev-override `compose config` check to CI (one line, **S**).

### Stage 2 — cheap upgrades from the ecosystem review

#### 2.1 Recommend Groq for transcription

Document in `.env.example` + `docs/configuration.md`:

```
VOICE_TRANSCRIPTION_BASE_URL=https://api.groq.com/openai/v1
VOICE_TRANSCRIPTION_MODEL=whisper-large-v3-turbo
VOICE_TRANSCRIPTION_API_KEY=gsk_...
```

- Pros: ~4× cheaper than the current default; free tier (~2k req/day) makes voice effectively free for personal use; no code change — takopi already supports a custom base URL; removes the OpenAI-key requirement for voice.
- Cons: another provider account; free-tier limits could change; 10-second minimum billing per request (irrelevant for voice notes).
- Keep OpenAI as the *default* for compatibility; make Groq the documented *recommendation*. Update the README cost table.
- Complexity: **S**.

#### 2.2 Teach the agent about Bases and modern frontmatter

Extend `vault/CLAUDE.base.md`:

- Plural-only frontmatter keys (`tags`/`aliases`/`cssclasses`) — prevents the agent writing frontmatter that Obsidian 1.9+ ignores.
- `.base` file basics (YAML: `filters`/`properties`/`views`) so "make me a table of all books I rated 5" produces a Base instead of a hand-maintained markdown table.
- Extend the operations taxonomy with proven vault-maintenance tasks (weekly review, merge duplicates, stale-note report) borrowed from obsidian-second-brain's command set.
- Pros: pure instruction change, immediately useful. Cons: longer system prompt → marginally higher per-message cost (prompt caching blunts this).
- Complexity: **S**.

#### 2.3 Refresh model guidance

`docs/configuration.md`: Haiku 4.5 stays the default; mention Sonnet 5 intro pricing ($2/$10 until Aug 31, 2026) as the "more capable" tier; note Fable-class models are not economical here.

- Complexity: **S**.

### Stage 3 — new capabilities

#### 3.1 Scheduled digest + nightly filing (the highest-value new feature)

The single most-loved feature across competing agents. Design options:

| Option | Pros | Cons | Complexity |
|---|---|---|---|
| **A (recommended): sidecar scheduler container** — a tiny cron image sharing `/vault`, running `claude -p "$(cat /vault/schedules/<task>.md)"` and posting results via Telegram Bot API (`curl`) | Self-contained in compose (survives VPS reprovisioning); tasks are user-editable markdown in the vault (synced to all devices!); same deny-list settings apply; no takopi changes | New container to build/maintain; second consumer of the Anthropic key (cost controls must account for it); needs its own session handling (`-p` one-shots are simplest) | **M–L** |
| B: host cron + script | Minimal code (a script + crontab line in docs) | Lives outside compose — lost on VPS rebuild, invisible to `docker ps`, harder to support | M |
| C: takopi scheduled messages (it supports Telegram scheduled sends) | Zero new components | Only *sends* scheduled messages; can't run an agent turn on schedule — doesn't actually cover digest/filing | S but insufficient |
| D: wait for bridge migration ([D1](#d1-bridge-strategy)) and use the Agent SDK's programmatic loop | Cleanest eventual architecture | Blocks a high-value feature on an XL project | — |

Recommended shape for A: `vault/schedules/morning-digest.md` and `vault/schedules/inbox-cleanup.md` as prompt files with a small YAML header (schedule, model, enabled); the sidecar reads headers, runs due tasks with `claude -p` (Haiku by default, Batches-friendly later), posts output to the bound chat. This also lays the groundwork for **natural-language self-scheduling** (the interactive agent writes new files into `schedules/` — feature 4 from [2.5](#25-competitor-features-worth-borrowing)) and a future **heartbeat** (a `schedules/heartbeat.md` running every N hours with "reply only if actionable").

Safety notes: digest tasks should default to **read-mostly** prompts; the inbox-cleanup task is the risky one — ship it disabled by default with a prominent backup warning, same policy as the main agent.

#### 3.2 Structured memory in the vault

- Ship templates: `vault/memory/USER.md` (facts/preferences the agent maintains), `memory/YYYY-MM-DD.md` daily activity logs; instructions in `CLAUDE.base.md` for when to read/update them.
- Consolidation (merge duplicates, decay stale facts) becomes a nightly `schedules/` task once 3.1 exists.
- Pros: persistent cross-session memory without any new infrastructure — it's just notes, synced and user-auditable in Obsidian. Cons: grows the prompt (mitigate: instruct the agent to read `USER.md` only, not the full log history); the agent editing its own memory files is a new failure surface for bad edits (mitigate: memory lives in the vault → covered by the same backup story).
- Complexity: **M** (mostly prompt engineering + templates).

#### 3.3 Optional semantic search

| Option | Pros | Cons | Complexity |
|---|---|---|---|
| **A: [tobi/qmd](https://github.com/tobi/qmd) as an opt-in compose service** — index `/vault`, expose the CLI to the agent (allowlist `Bash(qmd *)`) | Purpose-built for markdown; FTS5 + vectors on CPU; agent gets "what did I write about X?" beyond grep | Young project; index refresh scheduling; +RAM (small) | **M** |
| B: [basic-memory](https://github.com/basicmachines-co/basic-memory) MCP server | Knowledge-graph semantics (typed observations, relations); MCP-native | Heavier concept — wants to own note structure conventions; more opinionated than a search index | M–L |
| C: skip — Claude's Grep/Glob over a personal vault is adequate | Zero work, zero deps | Misses fuzzy/semantic recall on large vaults | — |

Recommendation: C now, A when a real user need appears (vaults under a few thousand notes are genuinely well-served by grep + the agent's iterative search).

#### 3.4 Remaining README roadmap items (unchanged status, for completeness)

- One-click deploy for DigitalOcean/Hetzner (cloud-init template around the existing non-interactive bootstrap — **M**, low risk, mostly docs + a `user-data` file).
- Safe slash-commands (`/capture`, `/append`, `/summarize`) — partially superseded by 3.1's task files; true slash-commands require bridge support (Takopi is dormant → realistically lands with [D1](#d1-bridge-strategy)).
- Git-based sync as an Obsidian Sync alternative — see [D3](#d3-sync-strategy).
- Demo video / asciinema — **S–M**, marketing value only.

---

## Part 4 — Strategic options

Bigger-picture directions. These are decisions, not tasks — each would reshape parts of the plan above.

### D1. Bridge strategy

The core dependency question: Takopi is dormant.

| Option | Pros | Cons | Complexity |
|---|---|---|---|
| **A (chosen): stay on Takopi, pin 0.23.4, document the risk** | Zero migration cost; battle-tested in this stack; feature set is already good (topics, voice, sessions, overflow handling) | Dormant upstream: no fixes for future Telegram API changes or Claude Code CLI breaking changes; 27 unmerged PRs of community fixes | **S** now |
| B: migrate to RichardAtCT/claude-code-telegram | Actively maintained; Agent-SDK-based; gains cron scheduler + webhooks + file uploads out of the box (covers much of Stage 3.1) | Different config surface → rewrite entrypoint/env/docs; different session model; project is one maintainer too — same class of risk, just currently active | **L** |
| C: own minimal bridge on the Claude Agent SDK | Full control; hooks/subagents/streaming programmatically; secrets handled our way (fixes S2 properly); slash-commands, scheduling, and heartbeat become first-class; smallest possible attack surface | It's a real project: Telegram long-polling, session persistence, voice pipeline, message splitting, error UX all reimplemented; ongoing maintenance moves onto this repo | **XL** |
| D: official Claude Code Channels | First-party, maintained by Anthropic | Architecture mismatch: requires a permanently-running interactive session (messages lost when down — unacceptable for a capture tool); no history; Bun dependency; research-preview status | M to try, but poor fit |

**Chosen: A now, C as the long-term roadmap direction.** Revisit if (a) a Telegram Bot API or Claude Code CLI change breaks Takopi, or (b) Stage 3 features start fighting the bridge's limits. Option C is assessed in depth — real code-size data from all alternatives, what to build, what to reuse, phased plan — in the dedicated [SDK bridge plan](sdk-bridge-plan.md); its headline: a purpose-built bridge is ~1.5–2.5k lines (the SDK absorbs what made Takopi 21k), start with a 2–4 day text-only spike behind a compose profile before committing.

> **Update (July 2026): option C is now the active direction** — the Stage 3 feature appetite materialized. The build specification (feature set, Takopi parity checklist, phases) lives in [bridge-spec.md](bridge-spec.md); Takopi remains the shipped default until the spec's Phase 4 cutover.

### D2. Runtime strategy: CLI shelling vs. Agent SDK

Independent of the bridge, the *scheduler* (3.1) and any future components should prefer the **Agent SDK** over `claude -p` when written in Python/TS: structured streaming events instead of stdout parsing, programmatic permission modes, in-process custom tools ("append to note" as a typed function instead of Bash), proper error handling. For shell-level one-shots, `claude -p` remains fine. No immediate action — a guideline for new code.

### D3. Sync strategy

| Option | Pros | Cons | Complexity |
|---|---|---|---|
| **A (current): Obsidian Sync via obsidian-headless** | Official; E2E-encrypted; instant multi-device including mobile; headless client now actively developed | $4/mo; pre-1.0 client; closed protocol | — |
| B: git-based sync (roadmap item) | Free; versioned history = built-in backup; works with any git host | No official mobile story (Working Copy/agit workarounds are fiddly); merge conflicts on binary attachments; sync latency; DIY conflict UX | **L** |
| C: Syncthing sidecar | Free; real-time; no cloud account | No Obsidian-aware conflict handling (`.sync-conflict` files pollute the vault); mobile background sync is unreliable on iOS | M–L |

Recommendation: keep A as the happy path; implement B as an *optional* profile for users who refuse the subscription — it doubles as the backup story. C not worth official support.

### D4. Transcription strategy

Covered in [2.3](#23-voice-transcription): document Groq as recommended (S, Stage 2.1). The fully-local GigaAM sidecar (RU-focused, ~250 MB, OpenAI-compatible shim needed) is a nice "no external voice provider" option but adds a service to maintain for a niche win — **only build if users ask** (complexity **L**: model serving, ffmpeg, language routing for non-RU audio).

### D5. Hosting strategy

Managed Agents (Anthropic-hosted loop, cron, memory stores) could eventually replace the VPS entirely, but the vault must then live inside Anthropic's sandbox — incompatible with Obsidian Sync headless today, beta API, vendor lock-in. **Watch.** Re-evaluate when it exits beta or gains external-volume mounting.

> **Update (July 2026): decided in the opposite direction** — the stack moves *toward* self-hosting, not away from it: onto the operator's **home server under Coolify**, published behind their own edge (VPS Traefik terminates TLS, Authentik authenticates) as tier A `agent.app.syntexia.ru`. It ships with the bridge's web-client track rather than as a separate project; the app-side contract, the phase impact and the new risks are in [bridge-spec — Deployment target](bridge-spec.md#deployment-target-the-home-server-under-coolify). Managed Agents stay on Watch, and the case for them is now weaker rather than stronger — the vault lives on hardware the operator owns, next to the SSO that guards it.

### D6. Prompt-injection hardening

Options, roughly in order of value-for-effort:

1. **Two-tier fetch flow** (M): instruct + hook-enforce that `WebFetch` results are summarized by a *subagent with no write tools*, and the main agent only files the summary. Blunts "the page told me to delete things" at the harness level.
2. **PreToolUse hooks** (S–M): block `Write`/`Edit` outside `/vault`, log every mutating tool call to an audit file in `takopi-state/`. Cheap, available today via `settings.json` — no SDK needed.
3. **Network egress allowlist** (M): compose-level DNS/proxy restricting outbound to Telegram/Anthropic/transcription APIs — turns "exfiltrate via crafted URL" into a hard failure. Costs the article-saving feature unless a fetch proxy is whitelisted; make it an opt-in profile like tmpfs isolation.
4. Accept-and-document (current state, S): honest, but the weakest.

Recommendation: 2 now (pairs naturally with Stage 1.2), 1 when convenient, 3 as an opt-in hardening profile documented next to tmpfs isolation.

### D7. Secrets in notes: layered protection + fixing the exclusion UX

Two distinct problems today: (a) credentials scattered inside ordinary notes reach the agent's context (and thus the Anthropic API, and potentially a Telegram reply or an injection-driven exfiltration); (b) the current folder-exclusion story is manual and split across three places (soft rules in `CLAUDE.local.md`, tmpfs mounts in `docker-compose.yml`, both edited by SSH on the VPS).

**Ground truth first:** anything the agent is *allowed* to read goes to the LLM provider. Reliable on-the-fly redaction is not achievable while `Bash`/`Grep` return raw text — so the goal is not "agent sees the note but not the password in it", it's **guaranteeing secrets don't live in the readable zone at all**. The layers:

| Layer | What | Enforcement strength | Needs SDK bridge? | Complexity |
|---|---|---|---|---|
| **L0: `.agentignore` in the vault root** | gitignore-syntax list of private paths as the *single source of truth*; syncs via Obsidian Sync → **editable from the phone in Obsidian**, no SSH | n/a (it's config) | No | **S** |
| **L1: generated tool-deny rules** | entrypoint parses `.agentignore` → `Read`/`Edit`/`Write`/`Grep` deny patterns in `settings.json` at container start | Blocks harness file tools; **does not** stop `Bash(cat …)` | No | **S** |
| **L2: kernel-level exclusion** | entrypoint expands `.agentignore` → `setfacl` deny (agent runs as non-root user) or generated tmpfs/bind overrides; refresh on restart + periodic re-scan for new dirs | **Hard** — even `cat`/`python` get `EACCES`; same strength as today's manual tmpfs, but automatic and vault-managed | No (requires the non-root container change) | **M** |
| **L3: nightly secret scanner** | gitleaks (MIT; mature regex + entropy rules) sweeps the vault *outside* ignored zones; findings reported to Telegram ("`Projects/homelab.md` appears to contain an API key — move it to a private folder / password manager?"), optionally auto-move behind a confirmation button | Detective, not preventive — catches the passwords exclusion lists can't know about | No (needs the 3.1 scheduler, or a minimal cron until then) | **M** |
| **L4: egress allowlist** | outbound network restricted to Anthropic/Telegram/transcription endpoints (= D6.3) | Blocks exfiltration even after a successful read + injection | No | M |
| L5: read-path redaction | SDK-bridge custom read tools masking secret patterns in output; hooks see resolved paths (symlink-proof) | Partial by construction (raw `Bash`/`Grep` bypass); defense-in-depth only | Yes | L, low value alone |

**Recommended shape:** L0+L1 immediately (pure entrypoint work, replaces the manual `CLAUDE.local.md` off-limits list); L2 as the real boundary (folds into the non-root container improvement); L3 once any scheduler exists; L4 as the opt-in hardening profile from D6. L5 only ever as icing. Net effect: private folders managed from any device by editing one file in Obsidian, kernel-enforced; stray credentials actively hunted down instead of silently uploaded.

---

## Part 5 — Suggested sequencing

| Order | Item | Complexity | Rationale |
|---|---|---|---|
| 1 | 1.1 CI race fix | S–M | Correctness of every future deploy depends on it |
| 2 | 1.2 deny-list + 1.3 secrets + D6.2 hooks + D7.L0/L1 `.agentignore` | S each | Security wins, trivially small; `.agentignore` also fixes the folder-exclusion UX |
| 3 | 1.4 docs drift | S | Cheap credibility |
| 4 | 1.5 pins + dependabot + SECURITY.md | M | Do before images drift further; unlocks headless 0.0.13 |
| 5 | 2.1 Groq docs + 2.2 Bases/frontmatter + 2.3 models | S each | Pure docs/prompt, immediate user value |
| 6 | 1.6 bats tests | M | Safety net before Stage 3 touches entrypoint logic |
| 7 | 3.1 scheduler + digest | M–L | Flagship feature; enables 3.2 consolidation and heartbeat |
| 8 | 3.2 memory templates | M | Rides on 3.1 |
| 9 | 3.4 one-click deploy, demo | S–M | Adoption polish |
| 10 | 3.3 semantic search, D3.B git sync, D1.C SDK bridge spike | M–XL | Demand-driven; spike before committing |

Items 1–5 fit comfortably in a single working session each; 6–8 are a session or two each; 10 needs its own design round.

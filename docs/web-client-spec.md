---
title: "Web client spec — Obsidian Telegram Agent"
description: "Specification for the self-hosted Android-first PWA client: browsable multi-session workbench, share-sheet capture, voice, Web Push, visual diff/undo, dashboards — served by the bridge as a second transport."
---

# Web client spec: the Android-first PWA workbench

← Back to [docs index](README.md) · Companion to the [bridge spec](bridge-spec.md)

The bridge core is transport-agnostic ([bridge-spec — Architecture](bridge-spec.md#architecture)). This document specifies its second transport: a self-hosted **PWA** served from the same VPS. It is not a Telegram clone in a browser — it is deliberately the *richer* half of a two-transport setup:

- **Telegram** (when reachable): thin, linear, fast capture. One active session, `/new`, done.
- **Web client**: the workbench. Every session ever created stays browsable and resumable; diffs are visual; usage, audit, and schedules have real UI. And it works from Russia without a VPN — your own domain on your own VPS is not Telegram, which has been [officially blocked/degraded in RU since February 2026](https://ru.wikipedia.org/wiki/%D0%91%D0%BB%D0%BE%D0%BA%D0%B8%D1%80%D0%BE%D0%B2%D0%BA%D0%B0_Telegram_%D0%B2_%D0%A0%D0%BE%D1%81%D1%81%D0%B8%D0%B8_(2026)).

Target device: **Android** (installed PWA). Desktop browsers work by construction. iOS is supported best-effort as an installed PWA but is not a target — iOS Safari has no `share_target`, so the capture flow degrades to copy-paste there.

- [Positioning and goals](#positioning-and-goals)
- [Architecture](#architecture)
- [Feature specification](#feature-specification)
- [Auth and exposure model](#auth-and-exposure-model)
- [Environment](#environment)
- [Testing](#testing)
- [Build plan](#build-plan)
- [Non-goals](#non-goals)

## Positioning and goals

1. **Sessions you can walk through.** The defining complaint about the Telegram flow: `/new` *erases* — the previous conversation is gone from your reach even though the work it did is in the vault. Here sessions are a sidebar: named, searchable, pinnable, archivable, each independently resumable. Starting fresh stops costing you history.
2. **Capture parity on Android.** "Share a link from any app → saved to the vault" must survive the move: PWA `share_target` receives URLs, text, and images from the Android share sheet.
3. **Interface features a chat message can't do**: visual per-file diffs with granular undo, editable voice transcripts before sending, a spend dashboard, tappable schedules and skills.
4. **No VPN in the loop.** Own domain + own VPS + AI Tunnel = a stack with no blocked component.

## Architecture

| Decision | Choice | Rationale |
|---|---|---|
| Server | **Same bridge process**: [Hono](https://hono.dev) serving static frontend + REST + WebSocket, mounted as the `web` transport adapter | One container, one healthcheck; the adapter speaks the same `Transport` interface as Telegram |
| TLS | **Caddy sidecar** container (compose profile `web`), automatic Let's Encrypt on `BRIDGE_WEB_DOMAIN` | Zero-config HTTPS; bridge itself never terminates TLS |
| Frontend | **Vite + Preact + TypeScript**, markdown-it + highlight.js, `idb` for offline queue; no component framework | Bundle target < 250 KB; the UI is one chat pane + one sidebar + a few panels — a heavy framework buys nothing |
| Streaming | **WebSocket** per client, multiplexing all sessions (events tagged with session id); REST for everything non-live | Live tool-activity timeline and steering need bidirectional; SSE would need a second channel for input |
| State | Rides on the bridge's session store (`bridge-state/sessions/` + display transcripts) — the web adapter adds only device registrations and push subscriptions | The workbench is a *view* over core state, not a second source of truth |
| Push | **Web Push (VAPID)** via the `web-push` library | Standard, no Firebase account; lands as native Android notifications with action buttons |

Frontend budget ~2.5k lines (`web-client/src/`): app shell + router ~200, chat pane + streaming timeline ~500, sessions sidebar ~250, capture flow ~250, voice recorder ~200, diff viewer ~300, dashboards (usage/audit/status) ~350, schedules + skills panels ~250, service worker (push, offline queue, share_target) ~200.

## Feature specification

### W-F1. Chat pane with live timeline

- Markdown rendered client-side — **no 4,096-char limits, no fence-splitting**: the entire Telegram rendering subsystem (bridge F3) simply does not apply to this transport.
- The agent's working state renders as a collapsible timeline inside the reply card (`📖 Read Inbox/… → ✏️ Edit Projects/…`), fed by the same events as bridge F4, delivered over WebSocket without the ≤1-edit/sec throttle.
- **Cancel / Steer** inline: a message typed while a turn runs offers Steer / Queue, same semantics as bridge F2.
- Vault paths in replies are links → read-only rendered **note preview** in a drawer (full editing stays Obsidian's job).
- `ask_user` (bridge F7) renders as an actionable card; if the app is closed, it arrives as a push notification with the answer buttons inline (Android notification actions).

### W-F2. Sessions sidebar — the headline feature

- List of all bridge sessions: pinned / recent / archived, with title, last activity, model chip, and running-turn indicator.
- **Auto-titling**: first exchange generates a short title via a one-shot Haiku call (editable).
- Switch instantly; each session resumes independently. Creating a session never destroys another — the Telegram habit of "затереть и начать заново" becomes "открыть новую вкладку".
- Full-text **search across transcripts** (server-side over the display-transcript jsonl).
- Per-session model override; archived sessions are read-only until explicitly reactivated.
- The Telegram transport's "active session" is just a pointer visible here — you can see what the bot chat is bound to and rebind it.

### W-F3. Capture (Android share sheet + quick capture)

- **`share_target`** in the manifest (`method: POST`, multipart): share a URL, selected text, or image from any Android app → a minimal capture sheet opens: destination chips (**Quick-save to Inbox** via the default capture skill / **Open in session…**), optional comment, send. Confirmation arrives as a push once the agent has filed it.
- Manifest **shortcuts**: long-press the app icon → "Capture", "New session".
- **Offline capture queue**: captures made offline are stored in IndexedDB by the service worker and submitted on reconnect — the "jot it down in the dead zone" case Telegram handled by being a message queue.

### W-F4. Voice

- Hold-to-record (MediaRecorder, webm/opus) → same `VOICE_*` transcription pipeline as Telegram.
- **Transcript shown for editing before send** (improvement over Telegram, where the voice note fires immediately); a per-setting auto-send mode restores the old behavior for speed.

### W-F5. Diff and undo workbench

- Every turn card that mutated the vault carries a chip ("3 files changed") → visual per-file diff (server renders from the checkpoint shadow repo, bridge F5).
- **Granular undo**: checkboxes per file → revert selection; the confirmation shows exactly what will change back. Strictly better than the chat `/undo`, and the natural home for the "sync pulled newer edits after the checkpoint" warning.

### W-F6. Dashboards

- **Usage**: daily/weekly/monthly spend chart, interactive vs scheduled split, per-session totals — graphical `/usage` (bridge F6).
- **Audit**: filterable view over `audit.jsonl` (by tool, path prefix, session, date).
- **Status**: bridge F13's `/status` as a panel — uptime, sync state, disk, checkpoint count, scheduler health.

### W-F7. Schedules and skills UI

- `vault/schedules/*.md` listed with next-run time, enabled toggle, **Run now** button, and last-run result; editing the body still happens in Obsidian — the UI only flips the typed header fields (same validated gate as the `schedule_task` tool).
- `vault/skills/*.md` (bridge F11) render as tappable chips above the composer, with an argument prompt where the template takes `{{args}}`.

### W-F8. Push notifications

- Web Push for: agent replies finished while the app is closed, scheduled-task results (digest, heartbeat), `ask_user` questions, budget-guard warnings (80%/100%), confirmation gates (H1), and anti-runaway trips (H4).
- Per-category toggles in settings; quiet hours honored server-side (`TZ`).

## Auth and exposure model

Adding an inbound HTTPS endpooint is the single biggest security change to a stack that currently has **zero open inbound ports** — it is treated accordingly:

- **Pairing, not passwords**: first device registers via a one-time claim URL/QR printed by `make claim-web` (same trust model as the Telegram claim token). Registration enrolls a **passkey (WebAuthn)**; subsequent devices are added from an already-authenticated device or a fresh claim token.
- Per-device revocable tokens (httpOnly, Secure, SameSite=Strict cookies); a devices panel in settings shows and revokes them.
- Attack surface discipline: exactly one unauthenticated route (`/pair/<token>`, rate-limited, tokens single-use and expiring); everything else 401s without a session. No CORS. Strict CSP, all assets self-hosted (mirrors the artifact-free, CDN-free frontend build).
- **Prerequisites made explicit**: a DNS A-record pointing `BRIDGE_WEB_DOMAIN` at the VPS, and inbound 80/443 opened in UFW *and* the provider firewall — the first inbound ports in this stack besides SSH. The installer checks both and refuses to enable the profile half-configured.
- Caddy handles TLS + login rate limiting; fail2ban on the VPS covers the rest (the [security checklist](security.md) gains a web section at cutover). The Caddy sidecar gets the same compose discipline as every other service: mem limit, log rotation, healthcheck.
- Optional stricter mode documented but not default: bind the web port to a WireGuard/Tailscale interface only — noted for completeness; the whole point of this client is working *without* a VPN, and domestic access to one's own VPS doesn't need one.
- H6 (outbound secret redaction) applies to this transport identically — redaction happens in the core, before any adapter.

## Environment

| Variable | Purpose |
|---|---|
| `BRIDGE_WEB_ENABLED` | Turn the web adapter on (default off; Telegram-only setups pay nothing) |
| `BRIDGE_WEB_DOMAIN` | Public domain for Caddy TLS |
| `BRIDGE_WEB_PUSH_VAPID_PUBLIC` / `_PRIVATE` | Web Push keys (`make web-keys` generates) |
| `BRIDGE_WEB_QUIET_HOURS` | e.g. `23-08`, suppress non-urgent push |

UI strings follow the bridge's `BRIDGE_LOCALE` (en/ru). Device registrations and push subscriptions live in `bridge-state/` and ride along in its backup scope ([bridge-spec — Deployment and operations](bridge-spec.md#deployment-and-operations)); revoking a device from the settings panel also drops its push subscription. The frontend bundle ships inside the bridge image (built in `build-images.yml`) — no separate deploy artifact.

Compose: profile `web` adds the Caddy sidecar and publishes 443; the bridge container itself stays unpublished.

## Testing

- Frontend unit tests only where logic lives (offline queue, transcript search, diff selection); rendering is covered by a small Playwright smoke suite (chromium is already in CI toolchains): pair → chat round-trip with stubbed core → share_target capture → diff view.
- The web adapter's REST/WS contract gets the same fake-core treatment as the Telegram adapter's fake Bot API tests (bridge [Testing](bridge-spec.md#testing-and-ci)).
- Lighthouse PWA budget in CI: installable, offline shell, bundle < 250 KB gzipped.

## Build plan

Parallel track; starts once bridge Phase 1 stabilizes the core API. Ordered so every phase ends in something usable daily.

| Phase | Content | Exit criteria | Effort |
|---|---|---|---|
| **W0 — Walking skeleton** | Hono adapter + WS streaming, Caddy profile, passkey pairing, minimal chat pane with markdown + timeline | Full conversation from a phone browser via the same core the Telegram adapter uses | 3–5 days |
| **W1 — Sessions** | Multi-session sidebar, auto-titling, search, per-session model, note preview drawer | The "walk through your sessions" promise delivered; daily-drivable in a browser tab | ~1 week |
| **W2 — PWA capture** | Manifest + service worker, install flow, `share_target`, shortcuts, voice with editable transcript, Web Push, offline capture queue | Share-sheet capture from any Android app; push-driven digest lands as a notification | ~1 week |
| **W3 — Workbench** | Diff viewer + granular undo, usage/audit/status dashboards, schedules + skills panels, quiet hours | The web client is strictly richer than Telegram for everything except being Telegram | ~1 week |

Dependencies on bridge phases: W0 needs Phase 1 (transport interface + session store); W3's diff workbench needs Phase 2 (checkpoints); schedules/skills panels need Phase 3. The tracks interleave naturally.

## Non-goals

- Multi-user, public SaaS, accounts
- Vault editing (Obsidian is the editor; the client previews)
- Native Android/iOS apps, iOS-specific engineering
- E2E encryption of the transport beyond TLS
- Realtime collaborative anything

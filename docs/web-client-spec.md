---
title: "Web client spec — Obsidian Telegram Agent"
description: "Specification for the self-hosted Android-first PWA client: browsable multi-session workbench, share-sheet capture, voice, Web Push, visual diff/undo, dashboards — served by the bridge as a second transport."
---

# Web client spec: the Android-first PWA workbench

← Back to [docs index](README.md) · Companion to the [bridge spec](bridge-spec.md)

The bridge core is transport-agnostic ([bridge-spec — Architecture](bridge-spec.md#architecture)). This document specifies its second transport: a self-hosted **PWA**, served by the bridge process itself from the home server under Coolify and published behind the operator's own edge as `agent.app.syntexia.ru`. It is not a Telegram clone in a browser — it is deliberately the *richer* half of a two-transport setup, and once the stack [moves home](bridge-spec.md#deployment-and-operations) it becomes the *primary* half:

- **Telegram** (when reachable): thin, linear, fast capture. One active session, `/new`, done. Best-effort after the move — a bridge polling `api.telegram.org` from a domestic ISP is not a transport to bet on.
- **Web client**: the workbench. Every session ever created stays browsable and resumable; diffs are visual; usage, audit, and schedules have real UI. And it works from Russia without a VPN — your own domain on your own infrastructure is not Telegram, which has been [officially blocked/degraded in RU since February 2026](https://ru.wikipedia.org/wiki/%D0%91%D0%BB%D0%BE%D0%BA%D0%B8%D1%80%D0%BE%D0%B2%D0%BA%D0%B0_Telegram_%D0%B2_%D0%A0%D0%BE%D1%81%D1%81%D0%B8%D0%B8_(2026)).

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
4. **No VPN in the loop.** Own domain + own infrastructure + AI Tunnel = a stack with no blocked component.
5. **No login code of our own.** The edge already runs Authentik for every other `*.app` service; this client inherits it and ships zero authentication ([Auth and exposure model](#auth-and-exposure-model)).

## Architecture

| Decision | Choice | Rationale |
|---|---|---|
| Server | **Same bridge process**: [Hono](https://hono.dev) serving static frontend + REST + WebSocket, mounted as the `web` transport adapter | One container, one healthcheck; the adapter speaks the same `Transport` interface as Telegram |
| TLS | **None in this stack.** The VPS Traefik terminates TLS for `*.app.syntexia.ru` and forwards over the Netmaker mesh to the home Coolify proxy, which routes by `Host` to the bridge's plain-HTTP port | The certificate, the domain and the ACME plumbing already exist at the edge; a Caddy sidecar would re-solve a solved problem and add a second TLS hop |
| Auth | **Authentik forward-auth** at the VPS edge (tier A) + a thin header check in the adapter | The operator already runs Authentik for every other `*.app` host; login, MFA, passkeys and session lifetime are its job, not this project's |
| Frontend | **Vite + Preact + TypeScript**, markdown-it + highlight.js, `idb` for offline queue; no component framework. **Domain-agnostic bundle** — nothing URL-shaped is inlined at build time | Bundle target < 250 KB; the UI is one chat pane + one sidebar + a few panels — a heavy framework buys nothing. The image is built in CI before the domain is known, so the origin comes from `location` at runtime |
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
- **Offline capture queue**: captures made offline are stored in IndexedDB by the service worker and submitted on reconnect — the "jot it down in the dead zone" case Telegram handled by being a message queue. Behind forward-auth this queue is not an optimization: *every* share goes through it, because the incoming POST must never reach the network ([What the proxy hop costs the PWA](#what-the-proxy-hop-costs-the-pwa)).

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

The client is published through infrastructure that already exists: the home Coolify proxy, the VPS Traefik, and Authentik — tier A of the homelab's [tiered wildcard routing](bridge-spec.md#deployment-and-operations), i.e. `agent.app.syntexia.ru`. That inverts what an earlier draft of this section assumed. Exposing the workbench is **not** "the single biggest security change to a stack with zero open inbound ports": it opens no port, adds no DNS record, terminates no TLS, and writes no authentication code. It adds one `Host` to an edge that already fronts a dozen services behind CrowdSec, norobots, and Authentik.

```
Phone ──HTTPS──▶ VPS Traefik ──forward-auth──▶ Authentik (auth.syntexia.ru)
                      │  TLS terminates here; CrowdSec + norobots + auth
                      ▼
              Netmaker mesh (WireGuard) — plain HTTP inside
                      ▼
              Coolify proxy (Traefik) ──HTTP──▶ bridge :3000
```

- **Authentik owns the login**, in domain-level forward-auth mode (external host `auth.syntexia.ru`, cookie domain `syntexia.ru`), so `*.app` hosts authenticate with no per-app provider. Everything the earlier draft planned to build is therefore **deleted from this spec**: one-time pairing tokens, WebAuthn enrollment, per-device revocable cookies, the devices panel, login rate limiting. Authentik does all of it, centrally, and already does it for the operator's other services. `make claim-web` disappears; `make web-keys` (VAPID) stays.
- **The adapter still checks, cheaply** — ~30 lines, not a subsystem. Forward-auth only protects what arrives *through Traefik*, and the container also sits on a Coolify docker network shared with every other app on the box, where nothing stops a neighbour from calling `http://bridge:3000/api/…` directly. So every request must satisfy both:
  1. `X-authentik-username` ∈ `BRIDGE_WEB_ALLOWED_USERS`. Traefik's `authResponseHeaders` **overwrite** these from the auth response on every request, so a client cannot forge them *through the edge*.
  2. `X-Bridge-Proxy-Secret` == `BRIDGE_WEB_PROXY_SECRET`, injected by a `customRequestHeaders` middleware. **Where it is injected decides what it proves.** On the *VPS* wildcard router it proves "this request crossed the edge, where Authentik ran" — the property actually wanted — at the cost of one tier-wide edit to `home-internal.yml` in the homelab repo (the wildcard model's "zero VPS-repo edits" promise is per *app*; this is one-time and shared by the whole tier). Injected on the *Coolify* side it only proves "came through the home proxy", leaving a mesh-side caller free to spoof `X-authentik-username`. Prefer the VPS side; the Coolify-side variant is the fallback if touching the VPS repo isn't wanted.

  Missing or mismatched → `401`, empty body. `BRIDGE_WEB_AUTH_MODE=none` exists for local development and refuses to start when `NODE_ENV=production`.
- **Zero unauthenticated routes.** `/healthz` is the only exception and the edge never routes it — the Docker `HEALTHCHECK` reaches it from inside the container. The old `/pair/<token>` route is gone with the pairing flow.
- No CORS. Strict CSP, all assets self-hosted (mirrors the CDN-free frontend build). H6 (outbound secret redaction) applies to this transport identically — redaction happens in the core, before any adapter.
- **Manual preconditions** — none of them new infrastructure, all checked by the installer, which refuses to enable the profile half-configured:
  - Coolify: domain set as `http://agent.app.syntexia.ru` — scheme **`http`**, **Force HTTPS off**. TLS is upstream; an app-side redirect sees `http` from the proxy and loops forever.
  - Authentik: outpost confirmed in domain-level forward-auth mode (already true for the rest of the tier).
  - `BRIDGE_WEB_PROXY_SECRET` present on both sides — the middleware and the app env.
  - Authentik session lifetime long enough for an installed PWA (see below).
  - An Uptime Kuma monitor on the app; the tier's SPOF is shared and now has no fallback transport ([bridge-spec — Risks](bridge-spec.md#risks)).

### What the proxy hop costs the PWA

Forward-auth is a redirect-based protocol, and the PWA mechanisms this client leans on hardest are redirect-hostile. Each is a design constraint on W2, not a blocker:

- **The `share_target` POST must never touch the network.** The Android share sheet issues a *cross-site* POST; Authentik's `SameSite=Lax` session cookie is not sent with it, forward-auth 302s to the login page, and the POST body — the thing being shared — dies on the redirect. The service worker therefore **must** intercept the share action in its `fetch` handler, parse the `FormData` in-page, persist it to IndexedDB, and answer with a local `Response.redirect()`; the real submit happens afterwards as a same-origin `fetch` from the SW, which *does* carry the cookie. This is the W-F3 offline queue running on every capture instead of only offline ones — same code, now mandatory rather than an optimization.
- **An expired session surfaces as HTML, not as 401.** Any same-origin `fetch` made after the Authentik session lapses resolves to a redirected `200` carrying a login page. Every API call checks `response.redirected` (or the absence of an `X-Bridge-API` marker header) and, on a miss, keeps the payload queued and prompts a full-page reload to re-authenticate — never silently drops a capture, never retries into a redirect loop.
- **WebSocket auth is handshake-only.** Cookies are checked once at the upgrade, so an open socket outlives session expiry and the *reconnect* is what fails — with a 302, not a clean close. The client treats "reconnect answered non-101" as "re-auth needed → reload", never as a transient network error to back off on.
- **Web Push is unaffected in transit** — browser↔push service and server↔push service both bypass the edge entirely — but a notification action button lands in the service worker, whose fetch hits the same expiry path as above.

Set the Authentik session for this application to weeks, not hours. An installed PWA that answers a morning digest with a login screen is a client the operator stops using.

## Environment

| Variable | Purpose |
|---|---|
| `BRIDGE_WEB_ENABLED` | Turn the web adapter on (default off; Telegram-only setups pay nothing) |
| `BRIDGE_WEB_PUBLIC_URL` | Final origin, e.g. `https://agent.app.syntexia.ru`. Used for absolute URLs in push payloads and as the `Host` allowlist — **never** compiled into the frontend bundle. `BRIDGE_WEB_DOMAIN` is read as a legacy alias |
| `BRIDGE_WEB_LISTEN` | Default `0.0.0.0:3000`. Must not bind `localhost` — Coolify proxies to the container by name, and a loopback bind is invisible to it |
| `BRIDGE_WEB_AUTH_MODE` | `proxy` (default): trust Authentik forward-auth headers. `none`: local development only; refuses to start under `NODE_ENV=production` |
| `BRIDGE_WEB_ALLOWED_USERS` | Comma-separated Authentik usernames allowed in |
| `BRIDGE_WEB_PROXY_SECRET` | Shared secret the edge injects as `X-Bridge-Proxy-Secret`; requests without it are 401 |
| `BRIDGE_WEB_PUSH_VAPID_PUBLIC` / `_PRIVATE` | Web Push keys (`make web-keys` generates) |
| `BRIDGE_WEB_QUIET_HOURS` | e.g. `23-08`, suppress non-urgent push |

UI strings follow the bridge's `BRIDGE_LOCALE` (en/ru). Push subscriptions live in `bridge-state/` and ride along in its backup scope ([bridge-spec — Deployment and operations](bridge-spec.md#deployment-and-operations)). The frontend bundle ships inside the bridge image (built in `build-images.yml`) — no separate deploy artifact.

**The domain is env, and never a build-time constant.** The bundle is built in CI, inside the bridge image, long before anyone assigns a domain in Coolify — so `VITE_*` inlining is banned for anything URL-shaped (the classic trap: the app is then wrong until someone remembers a *rebuild*, not a restart, is required). The client derives its origin from `location` and pulls everything else from a runtime `GET /api/config`. Payoff: moving the app to another subdomain — or between the `.app` and `.pub` tiers — is a Coolify env edit plus a restart.

**Trust the proxy; never redirect.** Hono has no `trust proxy` switch, so the adapter reads `X-Forwarded-Proto` / `-Host` / `-For` explicitly when building absolute URLs and resolving client IPs, marks its own cookies `Secure` unconditionally rather than inferring from the request scheme, and issues no HTTPS redirect of its own.

Compose: profile `web` only enables the adapter — no TLS sidecar, no published port. Under Coolify the bridge container publishes nothing at all; the proxy reaches it over the compose network.

## Testing

- Frontend unit tests only where logic lives (offline queue, transcript search, diff selection); rendering is covered by a small Playwright smoke suite (chromium is already in CI toolchains): chat round-trip with stubbed core and stubbed forward-auth headers → share_target capture → diff view.
- **Auth-boundary tests**, since the boundary is now two headers: a request with no `X-authentik-username` gets 401; a wrong/absent `X-Bridge-Proxy-Secret` gets 401; a username outside `BRIDGE_WEB_ALLOWED_USERS` gets 401; `BRIDGE_WEB_AUTH_MODE=none` under `NODE_ENV=production` fails to boot.
- **Redirect-hostility regressions** (the traps above, and the ones cheapest to break later): the share_target POST resolves entirely in the service worker with no network request; an API response carrying a login-page redirect queues rather than drops its payload.
- The web adapter's REST/WS contract gets the same fake-core treatment as the Telegram adapter's fake Bot API tests (bridge [Testing](bridge-spec.md#testing-and-ci)).
- Lighthouse PWA budget in CI: installable, offline shell, bundle < 250 KB gzipped.

## Build plan

Starts once bridge Phase 1 stabilizes the core API, and — since Telegram is demoted rather than merely unreliable — runs **ahead of bridge Phases 2–3** rather than beside them ([bridge-spec — Phased build plan](bridge-spec.md#phased-build-plan)). Ordered so every phase ends in something usable daily.

| Phase | Content | Exit criteria | Effort |
|---|---|---|---|
| **W0 — Walking skeleton** | Hono adapter + WS streaming, **the deployment-target switch** (VPS compose → home Coolify at `agent.app.syntexia.ru`, behind Authentik forward-auth + the header check), minimal chat pane with markdown + timeline | Full conversation from a phone browser via the same core the Telegram adapter uses | 3–5 days |
| **W1 — Sessions** | Multi-session sidebar, auto-titling, search, per-session model, note preview drawer | The "walk through your sessions" promise delivered; daily-drivable in a browser tab | ~1 week |
| **W2 — PWA capture** | Manifest + service worker, install flow, `share_target`, shortcuts, voice with editable transcript, Web Push, offline capture queue | Share-sheet capture from any Android app; push-driven digest lands as a notification | ~1 week |
| **W3 — Workbench** | Diff viewer + granular undo, usage/audit/status dashboards, schedules + skills panels, quiet hours | The web client is strictly richer than Telegram for everything except being Telegram | ~1 week |

Dependencies on bridge phases: W0 needs Phase 1 (transport interface + session store); W3's diff workbench needs Phase 2 (checkpoints); schedules/skills panels need Phase 3. The tracks interleave naturally.

W0 carries the hosting move because the web adapter cannot be tested without it: the domain, the forward-auth headers and the double-proxy hop *are* the thing under test. Everything after it — W1 sessions, W2 capture, W3 workbench — is ordinary product work against a deployed target.

## Non-goals

- Multi-user, public SaaS, accounts
- Authentication of any kind in this codebase (Authentik's job — including passkeys, MFA, and session lifetime)
- Vault editing (Obsidian is the editor; the client previews)
- Native Android/iOS apps, iOS-specific engineering
- E2E encryption of the transport beyond TLS
- Realtime collaborative anything

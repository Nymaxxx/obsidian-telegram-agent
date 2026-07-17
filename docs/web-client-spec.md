---
title: "Web client spec — Obsidian Telegram Agent"
description: "Specification for the self-hosted Android-first PWA: the bridge's only client — browsable multi-session workbench, share-sheet capture, voice, Web Push, visual diff/undo, dashboards, and the Coolify/Authentik exposure model."
---

# Web client spec: the Android-first PWA workbench

← Back to [docs index](README.md) · Companion to the [bridge spec](bridge-spec.md)

This is the bridge's **only client**: a self-hosted **PWA**, served by the bridge process itself from the home server under Coolify, published behind the operator's own edge as `agent.app.syntexia.ru`.

It was specified as the richer half of a two-transport setup. The other half is gone — [Telegram support is dropped](bridge-spec.md#goals-and-non-goals), because it has been [officially blocked/degraded in RU since February 2026](https://ru.wikipedia.org/wiki/%D0%91%D0%BB%D0%BE%D0%BA%D0%B8%D1%80%D0%BE%D0%B2%D0%BA%D0%B0_Telegram_%D0%B2_%D0%A0%D0%BE%D1%81%D1%81%D0%B8%D0%B8_(2026)) and the home network cannot poll it. So this document stops describing an alternative and starts describing *the* interface:

- Every session ever created stays browsable and resumable; diffs are visual; usage, audit, and schedules have real UI.
- No VPN anywhere in the loop: your own domain, on your own hardware, behind your own SSO.
- Nothing here is a compromise against a chat client that no longer exists — no 4,096-char limit, no parse mode, no message-edit throttle. Those were Telegram's constraints, and they left with it.

Being the only way in is also this design's sharpest risk, and it is recorded as one ([bridge-spec — Risks](bridge-spec.md#risks)).

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

1. **Sessions you can walk through.** The defining complaint about the chat flow being replaced: `/new` *erases* — the previous conversation is gone from your reach even though the work it did is in the vault. Here sessions are a sidebar: named, searchable, pinnable, archivable, each independently resumable. Starting fresh stops costing you history.
2. **Capture parity on Android.** "Share a link from any app → saved to the vault" is the headline use case and the one thing that must not regress: PWA `share_target` receives URLs, text, and images from the Android share sheet — from *any* app, which is strictly more than forwarding from inside one chat client ever reached.
3. **Interface features a chat message can't do**: visual per-file diffs with granular undo, editable voice transcripts before sending, a spend dashboard, tappable schedules and skills.
4. **No VPN in the loop.** Own domain + own infrastructure + AI Tunnel = a stack with no blocked component.
5. **No login code of our own.** The edge already runs Authentik for every other `*.app` service; this client inherits it and ships zero authentication ([Auth and exposure model](#auth-and-exposure-model)).

## Architecture

| Decision | Choice | Rationale |
|---|---|---|
| Server | **Same bridge process**: [Hono](https://hono.dev) serving static frontend + REST + WebSocket, mounted as the `web` transport adapter | One container, one healthcheck; the adapter speaks the core's `Transport` interface — now its only implementation |
| TLS | **None in this stack.** The homelab's edge Traefik terminates TLS for `*.app.syntexia.ru` and forwards over the Netmaker mesh to the home Coolify proxy, which routes by `Host` to the bridge's plain-HTTP port | The certificate, the domain and the ACME plumbing already exist at the edge; a Caddy sidecar would re-solve a solved problem and add a second TLS hop |
| Auth | **Authentik forward-auth** at the edge (tier A) + a thin header check in the adapter | The operator already runs Authentik for every other `*.app` host; login, MFA, passkeys and session lifetime are its job, not this project's |
| Frontend | **Vite + Preact + TypeScript**, markdown-it + highlight.js, `idb` for offline queue; no component framework. **Domain-agnostic bundle** — nothing URL-shaped is inlined at build time | Bundle target < 250 KB; the UI is one chat pane + one sidebar + a few panels — a heavy framework buys nothing. The image is built in CI before the domain is known, so the origin comes from `location` at runtime |
| Streaming | **WebSocket** per client, multiplexing all sessions (events tagged with session id); REST for everything non-live | Live tool-activity timeline and steering need bidirectional; SSE would need a second channel for input |
| State | Rides on the bridge's session store (`bridge-state/sessions/` + display transcripts) — the web adapter adds only push subscriptions (device *registration* died with the pairing flow; Authentik owns identity) | The workbench is a *view* over core state, not a second source of truth |
| Push | **Web Push (VAPID)** via the `web-push` library | Standard, no Firebase account; lands as native Android notifications with action buttons |

Frontend budget ~2.5k lines (`web-client/src/`): app shell + router ~200, chat pane + streaming timeline ~500, sessions sidebar ~250, capture flow ~250, voice recorder ~200, diff viewer ~300, dashboards (usage/audit/status) ~350, schedules + skills panels ~250, service worker (push, offline queue, share_target) ~200.

## Feature specification

### W-F1. Chat pane with live timeline

- Markdown rendered client-side — **no 4,096-char limits, no fence-splitting**. There is no server-side rendering subsystem to bypass: [bridge F3](bridge-spec.md#f3-rendering--removed) was deleted outright, not made optional.
- The agent's working state renders as a collapsible timeline inside the reply card (`📖 Read Inbox/… → ✏️ Edit Projects/…`), fed by bridge F4's event stream over WebSocket, at whatever rate the SDK produces it.
- **Cancel / Steer** inline: a message typed while a turn runs offers Steer / Queue, same semantics as bridge F2.
- Vault paths in replies are links → read-only rendered **note preview** in a drawer (full editing stays Obsidian's job).
- `ask_user` (bridge F7) renders as an actionable card; if the app is closed, it arrives as a push notification with the answer buttons inline (Android notification actions).

### W-F2. Sessions sidebar — the headline feature

- List of all bridge sessions: pinned / recent / archived, with title, last activity, model chip, and running-turn indicator.
- **Auto-titling**: first exchange generates a short title via a one-shot Haiku call (editable).
- Switch instantly; each session resumes independently. Creating a session never destroys another — the habit of "затереть и начать заново" becomes "открыть новую вкладку".
- Full-text **search across transcripts** (server-side over the display-transcript jsonl).
- Per-session model override; archived sessions are read-only until explicitly reactivated.

### W-F3. Capture (Android share sheet + quick capture)

- **`share_target`** in the manifest (`method: POST`, multipart): share a URL, selected text, or image from any Android app → a minimal capture sheet opens: destination chips (**Quick-save to Inbox** via the default capture skill / **Open in session…**), optional comment, send. Confirmation arrives as a push once the agent has filed it.
- Manifest **shortcuts**: long-press the app icon → "Capture", "New session".
- **Offline capture queue**: captures made offline are stored in IndexedDB by the service worker and submitted on reconnect — the "jot it down in the dead zone" case, previously handled for free by a chat client being a message queue, and now this client's own job. Behind forward-auth this queue is not an optimization: *every* share goes through it, because the incoming POST must never reach the network ([What the proxy hop costs the PWA](#what-the-proxy-hop-costs-the-pwa)).

### W-F4. Voice

- Hold-to-record (MediaRecorder, webm/opus) → the bridge's `VOICE_*` transcription pipeline, unchanged and transport-independent (it never had anything to do with Telegram beyond where the audio arrived from).
- **Transcript shown for editing before send** — a voice note used to fire blind the moment you released the button; a per-setting auto-send mode restores that behavior for speed.

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

The client is published through infrastructure that already exists: the home Coolify proxy, the homelab's edge Traefik, and Authentik — tier A of the homelab's [tiered wildcard routing](bridge-spec.md#deployment-target-the-home-server-under-coolify), i.e. `agent.app.syntexia.ru`. ("Edge" throughout means Traefik + Authentik on the homelab's public-facing VPS — infrastructure this project is *published through*, never *deployed to*; its own VPS is [retired entirely](bridge-spec.md#deployment-target-the-home-server-under-coolify).) That inverts what an earlier draft of this section assumed. Exposing the workbench is **not** "the single biggest security change to a stack with zero open inbound ports": it opens no port, adds no DNS record, terminates no TLS, and writes no authentication code. It adds one `Host` to an edge that already fronts a dozen services behind CrowdSec, norobots, and Authentik.

```
Phone ──HTTPS──▶ edge Traefik ──forward-auth──▶ Authentik (auth.syntexia.ru)
                      │  TLS terminates here; CrowdSec + norobots + auth
                      ▼
              Netmaker mesh (WireGuard) — plain HTTP inside
                      ▼
              Coolify proxy (Traefik) ──HTTP──▶ bridge :3000
```

- **Authentik owns the login**, in domain-level forward-auth mode (external host `auth.syntexia.ru`, cookie domain `syntexia.ru`), so `*.app` hosts authenticate with no per-app provider. Everything the earlier draft planned to build is therefore **deleted from this spec**: one-time pairing tokens, WebAuthn enrollment, per-device revocable cookies, the devices panel, login rate limiting. Authentik does all of it, centrally, and already does it for the operator's other services. `make claim-web` disappears; `make web-keys` (VAPID) stays.
- **The adapter still checks, cheaply** — ~30 lines, not a subsystem. Forward-auth only protects what arrives *through Traefik*, and the container also sits on a Coolify docker network shared with every other app on the box, where nothing stops a neighbour from calling `http://bridge:3000/api/…` directly. So every request must satisfy both:
  1. `X-authentik-username` ∈ `BRIDGE_WEB_ALLOWED_USERS`. Traefik's `authResponseHeaders` **overwrite** these from the auth response on every request, so a client cannot forge them *through the edge*.
  2. `X-Bridge-Proxy-Secret` == `BRIDGE_WEB_PROXY_SECRET`, injected by a `customRequestHeaders` middleware. **Where it is injected decides what it proves.** On the *edge* wildcard router it proves "this request crossed the edge, where Authentik ran" — the property actually wanted — at the cost of one tier-wide edit to `home-internal.yml` in the homelab repo (the wildcard model's "zero edge-repo edits" promise is per *app*; this is one-time and shared by the whole tier). Injected on the *Coolify* side it only proves "came through the home proxy", leaving a mesh-side caller free to spoof `X-authentik-username`. Prefer the edge; the Coolify-side variant is the fallback if touching the edge repo isn't wanted.

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

Forward-auth is a redirect-based protocol, and the PWA mechanisms this client leans on hardest are redirect-hostile. Each is a design constraint on Phase 3, not a blocker:

- **The `share_target` POST must never touch the network.** The Android share sheet issues a *cross-site* POST; Authentik's `SameSite=Lax` session cookie is not sent with it, forward-auth 302s to the login page, and the POST body — the thing being shared — dies on the redirect. The service worker therefore **must** intercept the share action in its `fetch` handler, parse the `FormData` in-page, persist it to IndexedDB, and answer with a local `Response.redirect()`; the real submit happens afterwards as a same-origin `fetch` from the SW, which *does* carry the cookie. This is the W-F3 offline queue running on every capture instead of only offline ones — same code, now mandatory rather than an optimization.
- **An expired session surfaces as HTML, not as 401.** Any same-origin `fetch` made after the Authentik session lapses resolves to a redirected `200` carrying a login page. Every API call checks `response.redirected` (or the absence of an `X-Bridge-API` marker header) and, on a miss, keeps the payload queued and prompts a full-page reload to re-authenticate — never silently drops a capture, never retries into a redirect loop.
- **WebSocket auth is handshake-only.** Cookies are checked once at the upgrade, so an open socket outlives session expiry and the *reconnect* is what fails — with a 302, not a clean close. The client treats "reconnect answered non-101" as "re-auth needed → reload", never as a transient network error to back off on.
- **Web Push is unaffected in transit** — browser↔push service and server↔push service both bypass the edge entirely — but a notification action button lands in the service worker, whose fetch hits the same expiry path as above.

Set the Authentik session for this application to weeks, not hours. An installed PWA that answers a morning digest with a login screen is a client the operator stops using.

## Environment

| Variable | Purpose |
|---|---|
| `BRIDGE_WEB_ENABLED` | Turn the web adapter on. Default **on** — it is the only client; the flag survives for local development and headless/scheduler-only runs |
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

Compose: no `web` profile any more — with one client there is nothing to gate behind one. The bridge serves it unconditionally, publishes no host port, and ships no TLS sidecar; Coolify's proxy reaches the container over the compose network.

## Testing

- Frontend unit tests only where logic lives (offline queue, transcript search, diff selection); rendering is covered by a small Playwright smoke suite (chromium is already in CI toolchains): chat round-trip with stubbed core and stubbed forward-auth headers → share_target capture → diff view.
- **Auth-boundary tests**, since the boundary is now two headers: a request with no `X-authentik-username` gets 401; a wrong/absent `X-Bridge-Proxy-Secret` gets 401; a username outside `BRIDGE_WEB_ALLOWED_USERS` gets 401; `BRIDGE_WEB_AUTH_MODE=none` under `NODE_ENV=production` fails to boot.
- **Redirect-hostility regressions** (the traps above, and the ones cheapest to break later): the share_target POST resolves entirely in the service worker with no network request; an API response carrying a login-page redirect queues rather than drops its payload.
- The web adapter's REST/WS contract is exercised against a stub core and a stub agent runtime (bridge [Testing](bridge-spec.md#testing-and-ci)) — with the renderer and splitter gone, this and the safety hooks are where the test budget goes.
- Lighthouse PWA budget in CI: installable, offline shell, bundle < 250 KB gzipped.

## Build plan

There is no separate track any more. With one client, "bridge core" and "web client" are the same project, so the former W-phases are simply phases of the [single build plan](bridge-spec.md#phased-build-plan), which is the authority on order, effort and gates. Their content, restated here as a map:

| Bridge phase | Delivers, for this client | Was |
|---|---|---|
| **0 — Spike** | A minimal chat pane over HTTP+WS on localhost, auth off, markdown rendered client-side. Proves the feel before any infrastructure exists | (new) |
| **1 — Deploy + core** | The Hono adapter, WS streaming, and the deployment move: Coolify at `agent.app.syntexia.ru` behind Authentik forward-auth + the header check. Live turn timeline, steering, voice | W0 |
| **2 — Sessions** | Multi-session sidebar, auto-titling, transcript search, per-session model, note-preview drawer | W1 |
| **3 — PWA capture** | Manifest + service worker, install flow, `share_target`, shortcuts, editable voice transcript, Web Push, offline capture queue | W2 |
| **6 — Workbench** | Diff viewer + granular undo, usage/audit/status dashboards, schedules + skills panels, quiet hours | W3 |

The workbench moved from "third client phase" to *last*: its panels are views over things that must exist first — checkpoints for the diff viewer (Phase 4), the scheduler and skills registry for their panels (Phase 5). Building the views first would mean building them against nothing.

The deployment move sits in Phase 1 rather than Phase 0 deliberately: the domain, the forward-auth headers and the double-proxy hop *are* what this client has to work through, so everything past the spike needs the real target — but the spike itself answers "does this feel right" on localhost, in an afternoon, and is the last cheap place to abandon the plan.

## Non-goals

- Multi-user, public SaaS, accounts
- Authentication of any kind in this codebase (Authentik's job — including passkeys, MFA, and session lifetime)
- Vault editing (Obsidian is the editor; the client previews)
- Native Android/iOS apps, iOS-specific engineering
- E2E encryption of the transport beyond TLS
- Realtime collaborative anything

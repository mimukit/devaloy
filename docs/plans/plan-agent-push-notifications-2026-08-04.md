# Plan — ntfy push notifications from Claude Code and Codex hooks

Grilled: 2026-08-04

## Context

devaloy runs agents on a VPS you are not sitting in front of. When Claude
finishes a turn or stops to ask permission, nothing tells you — the box has no
way to reach your phone. The Orca mobile app looks like it should cover this and
does not: Orca's mobile notifications are produced by a desktop **renderer**
window (`window.api.notifications.dispatch` → `ipcMain` →
`runtime.dispatchMobileNotification`), and `orca serve` returns from bootstrap
before `openMainWindow()`. A headless runtime has no renderer, so it has no
producer. Verified on the box: the container's Electron has zygote, gpu-process,
utility and broker processes and **no** `--type=renderer`; the laptop has one.

Orca also has no push service of any kind — delivery is a live control
WebSocket plus a 256-entry replay buffer drained on reconnect. Even a fixed Orca
would only reach a phone whose app is connected. So the fix is not "wait for
Orca": it is a notification path that hangs off the **hook contract** every agent
already implements, and therefore works for Claude Code, Codex, herdr, and
whatever comes next.

Success: an agent on devaloy stops for permission or finishes a long turn, and
within a couple of seconds the phone shows **one** notification per session that
updates in place — repo, state, elapsed — with no prompt or assistant text in
it, and with no measurable latency added to the agent's turn.

Scope for v1 is deliberately narrow. **Informational only** — no deep links, no
action buttons, no Orca or herdr integration. And **devaloy only** — the laptop
is where you already are when an agent finishes, so it keeps its existing
desktop toast and gains nothing.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Service | **ntfy.sh hosted, free tier** — 250 msg/day, no account, FCM-backed on the Play flavor so a backgrounded phone wakes at no battery cost. Self-hosting later is a base-URL change, not a rewrite. See `docs/research/` reasoning captured in session. |
| Where the notifications happen | **devaloy only.** The laptop is the machine you're sitting at; it already has Orca's toast and `terminal-notifier`. The push code does not even exist on the laptop (see below), so it can never fire there. |
| Where the code lives | **A new, devaloy-native `config/bin/agent-push`** — *not* a feature inside the shared `agent-hook` dispatcher. Reversed from an earlier draft that put `feat_push` in `agent-hook`: because `config/bin/agent-hook` is a byte-identical vendored copy of the chezmoi file (`private_dot_local/bin/executable_agent-hook`), any push code there would either fork the vendored file (forbidden) or ship inert on the laptop. A standalone script has no chezmoi upstream, so it is subject to no vendoring rule: `agent-hook` stays byte-identical, the laptop is untouched, and the whole feature is localized to this repo. The script is arg-dispatched — `agent-push <claude\|codex> <Event>` — mirroring `agent-hook`'s proven pattern, serving both agents from one auditable file. Seeded to `~/.local/bin/agent-push` by the existing `seed_config config/bin` copy; already on PATH; no new plumbing. |
| What turns it on | **Presence of config, not host detection.** `agent-push` no-ops unless a topic is configured. Only `entrypoint.sh` ever writes one, and only in the container. The laptop is off by *two* independent facts now — the script isn't there, and no config file would be either — rather than by a check that could regress. |
| Which events invoke it | The container's `config/claude/settings.json` and `config/codex/hooks.json` wire **`Notification`, `Stop`, and `UserPromptSubmit`** directly to `agent-push`. These are container-only files (seeded into `/home/dev`, never the laptop's own settings). `agent-hook` keeps its exact current wiring — `PreToolUse`→rm-guard, `SessionStart`→herdr — and is **not** touched by this plan. |
| Own gate, not `NOTIFY_SUPPRESS_VARS` | Moot now that push is a separate script: `agent-push` reads its own config and never consults `feat_notify`'s suppression list. `feat_notify` is left entirely alone. |
| Where config is read from | A file (`~/.config/agent-push.env`), sourced by `agent-push` itself — **not** inherited env. Orca spawns panes via `su -l -s /bin/sh`, which reads neither `.zshenv` nor `.bashrc`, so `~/.devaloy_secrets` is not reliably in a hook's environment. Env vars still win when set. |
| Which events fire a notification | `Notification` (agent is blocked — the one you actually want) and `Stop` (turn ended). `UserPromptSubmit` is wired as a **timestamp only**, never a notification. `SubagentStop`, `PostToolUse` and friends stay unwired. |
| Suppressing "I'm watching this" | **Deferred — decided by the Phase 0 spike.** The candidate proxy is: notify on `Stop` only when the turn ran ≥ `PUSH_MIN_TURN_SECONDS` (default 60), elapsed from the `UserPromptSubmit` stamp. But Orca's own shipped model (verified in its source) uses *no* watching-heuristic at all — just event + a 5s per-worktree cooldown. Which model we adopt hinges on whether an in-place update **re-buzzes** the phone or updates **silently**: if silent, the cooldown alone is enough (Orca's model); if it re-buzzes, the duration proxy earns its keep against a burst of short turns you're sitting in front of. The spike answers that before this is finalized. `Notification` always fires regardless — being blocked is worth interrupting for. |
| Debounce | Per-session cooldown, default 30s, via mtime on a state file. Orca's precedent (confirmed in its source: `NOTIFICATION_COOLDOWN_MS = 5e3`, keyed per worktree) is 5s; ours is longer because our trigger is coarser. |
| Daily quota guard | **A dated send counter** in the state dir. The per-session cooldown bounds *rate* but not the *daily total* — one looping session at a 30s cooldown could emit ~2,880/day and silently blackout the 250/day free tier (each in-place update still costs a message). So `agent-push` stops sending at a soft cap (~200/day, headroom under 250), `log()`s once when it trips so the blackout isn't fully silent, and resets on date change. Vanishes for free once self-hosted. |
| One notification per session | ntfy's **`sequence_id`** update-in-place: publish with a stable sequence id derived from the session, so the phone shows a single entry per session that mutates rather than a pile. Sent as the `X-Sequence-ID` header (or the URL path `POST /<topic>/<sequence_id>`). Requires ntfy server **v2.16.0** (2026-01-19) and Android app **v1.22.2+** (2026-01-20); works on the anonymous free tier with no auth. *(An earlier draft named this `X-Message-ID`/`?message_id=`; that was a stale source — the mechanism is `sequence_id`. Confirmed against docs.ntfy.sh and the release notes.)* |
| Message content | Metadata only: agent, repo/worktree, state, elapsed, host. **Never** prompt, assistant text, or `tool_input`. A free-tier topic is unreserved — anyone who knows the string can read it — so the topic is a secret *and* the payload is boring. Leaking repo/worktree basenames and activity timing is judged acceptable; self-hosting with ACLs stays the later escape hatch if that ever changes. |
| Transport | Synchronous `curl` with `--connect-timeout 0.5 --max-time 1.5`, output discarded, always `return 0`. Same shape as Orca's own relay hook. No backgrounding: a detached child that outlives the hook risks writing to a pipe the agent is parsing. |
| Failure behaviour | Fails open and silent, like every dispatcher feature except `rm-guard`. A dead network must never break a turn. |

## Approach

Six phases. Phase 0 is an empirical spike that settles two deferred decisions
before any code depends on them. Phase 1 is a prerequisite wiring change with no
user-visible effect; phases 2–3 are the feature; 4 makes it deployable; 5
proves it.

**What this reuses:** the `agent-hook` dispatcher's four load-bearing design
rules as a *template* for the new script (only the delete-guard writes to stdout;
everything else fails open; stdin drained once into `$payload`; always exit 0),
its `payload_get` jq helper idiom, `entrypoint.sh`'s `write_secret` +
`seed_config` merge-copy, the `.env` → `~/.devaloy_secrets` (0600) channel, the
existing `seed_config config/bin` copy that will carry `agent-push`
automatically, and `docs/wiki/` for the operator page. It does **not** modify
`agent-hook`, `rm-guard`, or any laptop/chezmoi file.

### Phase 0 — Spike: pin the ntfy behaviour on the real phone

One-shot manual publishes to a throwaway topic, from a laptop shell, before any
of it is wired to a session. This settles the two deferred decisions and the
Android-16 risk empirically rather than by guess. Three questions:

1. **Does `sequence_id` update-in-place work?** Publish twice to the same
   sequence id and confirm the phone shows one entry that mutates, not two.
   Confirms the mechanism and the server/app versions in play. If it does not
   work as documented, "one notification per session" degrades to "tags plus a
   longer cooldown" — decide then whether that's acceptable.
2. **Does an in-place update re-buzz, or update silently?** This picks the
   watching-heuristic: silent updates → adopt Orca's model (event + cooldown, no
   duration proxy); re-buzzing updates → keep the `PUSH_MIN_TURN_SECONDS`
   duration proxy to suppress bursts of short turns.
3. **Android 16 #117 — does a second push from a *new* session key stay
   audible** while the first is still on screen? Real, open, OS-level bug
   (`ntfy-android#117`): a second *distinct* ungrouped notification gets a
   `SILENT` flag until the group is dismissed. Update-in-place (same sequence
   id) is a different code path and likely unaffected, so the risk is
   cross-session only, and there is **no publisher-side fix**. If it reproduces
   on your phone, document it as a known v1 limitation (the OS fix is reportedly
   propagating) and ship anyway — the within-session and blocked-for-permission
   cases still work.

### Phase 1 — Wire the events that currently don't fire

The container's `config/claude/settings.json` and `config/codex/hooks.json` route
only `PreToolUse` (→ `agent-hook`, rm-guard) and `SessionStart` (→ herdr's own
script). Until `agent-push` is wired, **nothing in phases 2–3 can ever run on the
box**.

- Add `Notification`, `Stop`, `UserPromptSubmit` entries pointing at
  `bash "$HOME/.local/bin/agent-push" claude <Event>` in
  `config/claude/settings.json`.
- Same three for `codex` in `config/codex/hooks.json` (no `matcher` — Codex has
  no matcher support).
- **Do not touch `agent-hook`'s wiring or the vendored file.** On the container
  those three events were previously unwired, so there is no coexistence dance:
  we are only *adding* entries that point at the new script.
- Leave Orca's and herdr's own entries alone; they are installed and maintained
  by those tools and coexist by design.
- Verify on the box that a redeploy's merge-copy actually replaces the files and
  that Orca does not strip our entries when it reinstalls its own.

### Phase 2 — `agent-push`, the standalone hook script

`config/bin/agent-push`. Self-contained: it borrows `agent-hook`'s structure as
a template but shares no code with it (keeping the two decoupled is the whole
point). Arg-dispatched `agent-push <claude|codex> <Event>`, payload JSON on
stdin.

- **Skeleton (from the dispatcher's rules):** drain stdin exactly once into
  `$payload`; a local `payload_get` jq helper; never write to stdout; always
  `exit 0`; no `set -e`.
- **Config load:** source `~/.config/agent-push.env` if readable; honour pre-set
  env vars over it. Keys: `PUSH_NTFY_URL` (default `https://ntfy.sh`),
  `PUSH_NTFY_TOPIC` (required — absent means feature off), `PUSH_NTFY_TOKEN`
  (optional, for a future authed/self-hosted server), `PUSH_MIN_TURN_SECONDS`,
  `PUSH_COOLDOWN_SECONDS`, `PUSH_DAILY_CAP` (default ~200). Return early with no
  network if `PUSH_NTFY_TOPIC` is unset — this is the gate that makes the script
  safe to exist anywhere.
- **Identity:** session id from the payload (`.session_id` for Claude, with
  fallbacks for Codex), hashed with the cwd to form both the state-file name and
  the ntfy **sequence id**. Falls back to a cwd-only key when no session id is
  present, so Codex still collapses per workspace. *(Codex's `Stop`/`Notification`
  field shape is unverified — the `.tool_name // .tool_input.tool_name` fallback
  chain in `agent-hook` suggests Codex payloads differ; confirm the actual field
  names when wiring, but per-directory collapse is the acceptable graceful
  degradation either way.)*
- **Body builder:** title `<Agent> · <basename of cwd>`, body
  `<state> · <elapsed>`, plus `X-Priority` (4 for `Notification`, 3 for `Stop`),
  `X-Tags`, and `X-Sequence-ID` (the session sequence id). Explicitly drops every
  free-text field in the payload. This function is the security boundary — a
  standalone script *is* the "short enough to audit at a glance" surface the
  design wanted.
- **Send:** one `curl`, bounded timeouts, all output to `/dev/null`, `return 0`
  unconditionally.

### Phase 3 — Debounce, daily cap, and the "am I watching" gate

State lives in `${XDG_RUNTIME_DIR:-/tmp}/agent-push/`, one file per session key,
plus a dated daily-counter file.

- `UserPromptSubmit` writes the turn-start stamp and nothing else.
- `Stop` computes elapsed. The watching-gate is finalized per Phase 0: either the
  `PUSH_MIN_TURN_SECONDS` duration proxy (below it, return without sending) or
  Orca's cooldown-only model. Missing stamp (e.g. a session that started before
  this shipped) counts as "long enough" — better a spurious notification than a
  silent one.
- Both events check a per-key cooldown stamp before sending and refresh it
  after.
- **Daily cap:** before sending, read the dated counter; if it is at
  `PUSH_DAILY_CAP`, `log()` once and return without sending. Otherwise send and
  increment. Reset (or roll the filename) on date change.
- Prune stamps older than a day on entry so the directory can't grow unbounded.

### Phase 4 — Config plumbing and docs

- `.env.example`: `NTFY_TOPIC`, optional `NTFY_SERVER`, `NTFY_TOKEN`, with the
  comment block explaining that the topic **is** the credential and must be long
  and random.
- `entrypoint.sh`: `write_secret` the three values, and write
  `~/.config/agent-push.env` (0600, owned by `dev`) from them — mapping
  `NTFY_TOPIC`/`NTFY_SERVER`/`NTFY_TOKEN` to the script's
  `PUSH_NTFY_TOPIC`/`PUSH_NTFY_URL`/`PUSH_NTFY_TOKEN` — so hooks read it
  regardless of how their shell was spawned. Rewritten from scratch each boot,
  like `~/.devaloy_secrets`, so clearing `.env` really does disable it.
- `docs/wiki/push-notifications.md`: what it sends, what it deliberately does
  not send, how to pick a topic, how to turn it off, the free-tier quota and the
  daily cap, and the Android-16 #117 caveat if it reproduced.
- Note in `README.md` next to the other opt-in features.

### Phase 5 — Verification

- Feed a recorded Claude `Stop` payload into `agent-push` on the laptop
  (no config file) and assert zero network calls and empty stdout. This is the
  config-gate regression test — it keeps "devaloy only" true even though the
  script now ships nowhere near the laptop, and it should outlive this plan.
- Same on the box with config present: assert one notification, correct title,
  no prompt text anywhere in the request body.
- Two `Stop`s inside the cooldown → one notification.
- If the duration proxy survived Phase 0: a `Stop` after a 5-second turn → no
  notification; after 90 seconds → one.
- Daily cap: drive `PUSH_DAILY_CAP + 1` sends → the last is suppressed and
  logged once.
- Time the hook: `PreToolUse` + `Stop` round-trip must stay well inside the
  10-second hook timeout even with the network black-holed.
- QA doc via qakit once it works.

## Resolved open questions

- **Update-in-place mechanism — RESOLVED.** It is `sequence_id`
  (`X-Sequence-ID` header / `POST /<topic>/<sequence_id>` path), server v2.16.0 +
  app v1.22.2, anonymous free tier. The `X-Message-ID`/`?message_id=` naming was
  stale. Phase 0 still confirms it works on your specific phone/app version.
- **Android 16 may sabotage the premise — VERIFY, THEN ACCEPT.** `ntfy-android#117`
  is real and open but OS-level, cross-session only, and unfixable from the
  publisher. Phase 0 checks reproduction; v1 ships regardless with it documented.
- **Turn duration as the "not watching" proxy — DEFERRED to Phase 0.** Orca ships
  no such heuristic (event + 5s cooldown); ours is justified only if in-place
  updates re-buzz. The spike decides. tmux/`herdr` attach-state was investigated
  and rejected: herdr (the primary runner) exposes agent working/idle state, not
  client-attached state, and tmux is only a fallback — so no clean direct signal
  exists for the main path.
- **Codex payload field names — VERIFY AT IMPLEMENTATION.** Not a blocker: the
  session-id → cwd-only fallback collapses per workspace when Codex carries no
  session id, which is the acceptable degradation. Confirm the field shape when
  wiring Phase 2.
- **Quota vs runaway loop — RESOLVED: add a daily counter.** The cooldown bounds
  rate, not daily total; a dated soft-cap counter (~200/day, logged once on trip)
  is the cheap insurance. See the "Daily quota guard" row.
- **Topic secrecy is the whole security model — RESOLVED: acceptable, keep the
  door.** Metadata-only content makes the unreserved topic's readability a
  non-event; self-hosting with ACLs stays the later escape hatch, not v1 scope.
- **Visibly-inert laptop code — DISSOLVED.** No longer applicable: the push code
  is a devaloy-native script that never ships to the laptop, so there is no inert
  code to document. This was the trigger for reversing the "where the code lives"
  decision.

## Non-goals

- **No push from the laptop.** It keeps Orca's desktop toast and
  `terminal-notifier`; `agent-push` never ships there. If that ever changes it is
  a new deployment target, not a code change here.
- **No changes to `agent-hook`, `rm-guard`, or any chezmoi/laptop file.** The
  whole feature is localized to this repo's container config.
- **No Orca or herdr integration.** No `orca://` deep links, no click-through
  targets, no plugin. Informational only.
- **No action buttons.** ntfy supports three; v1 sends none.
- **No fix for the Orca bug.** Reporting it upstream is separate work.
- **No self-hosted ntfy.** The design keeps the door open (`PUSH_NTFY_URL`,
  `PUSH_NTFY_TOKEN`) and walks through it later if privacy demands it.
- **No iOS.** The FCM reasoning is Android-specific and ntfy's iOS app is, by
  its author's own description, bare bones.
- **No changes to `feat_notify`, `feat_rm_guard`, or `feat_port_cleanup`.**
- **No new runtime dependency.** `curl` and `jq` are already on both hosts.

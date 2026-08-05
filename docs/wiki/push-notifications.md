# Push notifications to your phone

devaloy runs agents on a box you are not sitting in front of. When Claude Code
or Codex **blocks for permission** or **finishes a long turn**, `agent-push`
sends one [ntfy](https://ntfy.sh) notification to your phone — repo, state,
elapsed time, host — that **updates in place** so you get a single entry per
session, not a pile.

It is **off by default** and opt-in with one `.env` variable. This is a devaloy
feature only: the laptop already has Orca's desktop toast, and `agent-push`
never ships there.

## Turn it on

1. Pick a **long, random** topic string — this is the credential (see
   [Security](#security-what-the-topic-is)):

   ```sh
   openssl rand -hex 16
   ```

2. Put it in `.env` and redeploy:

   ```sh
   NTFY_TOPIC=<the-random-string-from-above>
   ```

   ```sh
   docker compose up -d
   ```

3. Install the **ntfy** app ([Play
   Store](https://play.google.com/store/apps/details?id=io.heckel.ntfy) /
   [F-Droid](https://f-droid.org/en/packages/io.heckel.ntfy/)) and subscribe to
   your topic, or open `https://ntfy.sh/<your-topic>` in a browser to watch it.

That is the whole setup. `entrypoint.sh` writes `~/.config/agent-push.env` on
the box from your `.env`, and the hooks are already wired.

## Turn it off

Remove (or blank) `NTFY_TOPIC` in `.env` and redeploy. The config file is
rewritten from scratch every boot, so clearing the variable really does disable
it — and `agent-push` no-ops with no network when no topic is configured.

## What it sends — and what it never sends

**Sends** (metadata only):

- the agent — `Claude Code` or `Codex`
- the working directory **basename** (e.g. `devaloy`, not the full path)
- the state — `Needs your input` or `Turn finished`
- elapsed turn time and the host name

**Never sends:** your prompt, the assistant's replies, tool inputs, file
contents, full paths, or anything else free-text. The message is built from a
fixed vocabulary plus the directory basename — nothing from the payload's text
fields ever leaves the box.

## Security: what the topic is

An ntfy.sh topic on the free tier is **unreserved** — anyone who knows the topic
string can subscribe and read every message on it. So **the topic string is the
credential**. Two things follow:

- **Choose a long, random topic** (`openssl rand -hex 16`), never a guessable
  name like `devaloy` or your username.
- The payload is deliberately **boring** — leaking a repo basename and activity
  timing is judged acceptable; leaking prompt or code would not be, which is why
  none is sent.

If that trade ever stops being acceptable, self-host ntfy with access control
and point `NTFY_SERVER` (and `NTFY_TOKEN`) at it — no code change here.

## Tuning

Optional `.env` values, all with sensible defaults:

| Variable | Default | Meaning |
|----------|---------|---------|
| `NTFY_TOPIC` | *(unset — off)* | The topic. Setting it enables the feature. |
| `NTFY_SERVER` | `https://ntfy.sh` | Base URL. Point at a self-hosted server here. |
| `NTFY_TOKEN` | *(none)* | Bearer token for an authed/self-hosted server. |

The script itself also honours these (set them in `~/.config/agent-push.env` on
the box if you want to override the defaults):

| Variable | Default | Meaning |
|----------|---------|---------|
| `PUSH_MIN_TURN_SECONDS` | `60` | `Stop` only notifies for turns at least this long, to skip short turns you were watching. `0` disables the check. |
| `PUSH_COOLDOWN_SECONDS` | `30` | Minimum gap between pushes for one session. |
| `PUSH_DAILY_CAP` | `200` | Soft daily send cap (see below). |

## Quota and the daily cap

The ntfy.sh free tier allows **250 messages/day**, and every in-place update
still costs one message. A looping session could otherwise exhaust that and
black the topic out silently, so `agent-push` stops sending at a soft cap
(`PUSH_DAILY_CAP`, default 200) and logs once when it trips. The counter resets
at midnight (box time). Self-hosting removes the limit entirely.

## Known limitation — Android 16 (`ntfy-android#117`)

On some Android 16 builds, when a **second, different** session's notification
arrives while an earlier one is still on screen, the OS may deliver it silently
(no sound/vibration) until you dismiss the group. This is an **OS-level ntfy-app
bug** ([`ntfy-android#117`](https://github.com/binwiederhier/ntfy-android/issues/117)),
not something the sender can fix. Notes:

- In-place updates to the **same** session (the common case) are a different
  code path and are not affected.
- Being **blocked for permission** always fires at high priority.
- The reported fix is propagating through OS updates.

If you rely on audible alerts from multiple concurrent sessions, keep this in
mind until your phone picks up the fix.

## How it works (internals)

- **`config/bin/agent-push`** — a standalone hook script (seeded to
  `~/.local/bin/agent-push`), arg-dispatched `agent-push <claude|codex>
  <Event>`. It is the only hook script this repo ships — the `agent-hook`
  dispatcher and its `rm-guard` delete check were removed from the box.
- **Events** (wired in `config/claude/settings.json` and
  `config/codex/hooks.json`): `UserPromptSubmit` records the turn-start time,
  `Notification` fires when the agent blocks, `Stop` fires when a long turn
  ends.
- **One entry per session:** the ntfy `X-Sequence-ID` header, derived from the
  session id and cwd, makes the phone update a single notification in place.
- **Fails open:** a single bounded `curl` (`--max-time 1.5`), all output
  discarded, always exits 0. A dead network can never break or slow a turn.

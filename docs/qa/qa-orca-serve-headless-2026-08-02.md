# QA Plan: `orca serve` headless on devaloy

_Generated 2026-08-02 · covers `df83e5c..HEAD` — the optional Orca runtime:
`ARG WITH_ORCA`, the gated Dockerfile block, the supervised launch in
`entrypoint.sh`, the compose wiring, and the docs._

_Design of record:
[`docs/plans/plan-orca-serve-headless-2026-08-02.md`](../plans/plan-orca-serve-headless-2026-08-02.md),
grilled 2026-08-02. This plan is that plan's **Phase 4**._

_Target environment for this pass: an **OrbStack Linux machine on an arm64 Mac**,
not a VPS. That is a deliberate change of venue — see
[What this venue does and does not prove](#what-this-venue-does-and-does-not-prove)._

## Summary

- devaloy can optionally run an Orca runtime, so the Orca **desktop and mobile
  apps** can drive the box — something Tailscale SSH cannot offer, because
  those apps talk to a runtime rather than a terminal.
- "Working" means: you build with `WITH_ORCA=true`, the box joins the tailnet,
  the server binds and prints a pairing URL, the desktop app pairs over the
  tailnet, an agent actually **runs** from that client, and the pairing survives
  `docker compose down && up`. And with `WITH_ORCA` unset, none of it exists and
  nothing complains.

## What this venue does and does not prove

OrbStack is a good venue for everything except the two things that need real
hardware pressure:

| Proves | Does not prove |
|---|---|
| The arm64 deb path, which is the one the automated checks already exercised | Behaviour on an `amd64` VPS — the `ARCH` branch is untested on real x86 |
| Cold boot, pairing, redeploy persistence, the `--build` footgun | Memory pressure with the agent fleet running (TC-13 is a proxy, not a proof) |
| That SSH stays the recovery path | Sustained multi-day uptime, and whether the autoupdater ever finds an update |

## Preconditions

### On the OrbStack Linux machine

- OrbStack running, with a Linux machine you can get a shell in. Everything
  below runs **inside** that machine, not on macOS.
- `/dev/net/tun` must exist — the container gets `NET_ADMIN` but deliberately
  not `SYS_MODULE`, so it cannot load the module itself:

```sh
ls -l /dev/net/tun || sudo modprobe tun
```

- This branch checked out. It is **committed** (`af99e4f`), so a normal clone or
  pull is enough.
- A `.env` from `.env.example` with a **reusable, non-expiring, untagged**
  `TS_AUTHKEY`. Leave `WITH_ORCA` out for now — TC-2 starts from the default.
- Roughly **4 GB of free disk**: the two images are 683 MB and 1.6 GB, and the
  build downloads a 154 MB deb.

### On the tailnet

- An `ssh` rule in the [policy file](https://login.tailscale.com/admin/acls)
  granting `autogroup:member` → `autogroup:self` as user `dev`. Without it you
  join the tailnet and still cannot log in.
- No stale `devaloy` node in the admin console, or MagicDNS will hand out
  `devaloy-1` and every address below will be wrong.

### On the Mac and phone

- Tailscale connected on the Mac, and the **Orca desktop app** installed.
- Tailscale connected on the phone, and the **Orca mobile app** installed.
  The phone needs Tailscale *actually connected*, not merely installed — the
  pairing link carries a `100.x` address that is otherwise unroutable.

### Launch

```sh
docker compose up -d --build
```

## Test cases at a glance

Priority legend: 🔴 Critical · 🟡 Normal · 🟢 Low

| # | Test case | Priority |
|---|-----------|----------|
| TC-1 | Default build is silent and Orca-free | 🔴 Critical |
| TC-2 | Cold boot with `WITH_ORCA=true` reaches a pairing URL | 🔴 Critical |
| TC-3 | Pair the Orca desktop app over the tailnet | 🔴 Critical |
| TC-4 | An agent actually runs from the Orca client | 🔴 Critical |
| TC-5 | Pairings survive `down && up` — and rule on dbus | 🔴 Critical |
| TC-6 | Tailscale SSH and herdr still work unchanged | 🔴 Critical |
| TC-7 | `up -d` without `--build` silently changes nothing | 🟡 Normal |
| TC-8 | Pair the phone, or establish what it needs | 🟡 Normal |
| TC-9 | The supervised restart loop actually restarts | 🟡 Normal |
| TC-10 | No tailnet means no server, and a warning that says so | 🟡 Normal |
| TC-11 | Port 6768 is reachable from the host, and nowhere else | 🟡 Normal |
| TC-12 | The on-box agent check command tells the truth | 🟢 Low |
| TC-13 | Orca dies before `tailscaled` under memory pressure | 🟢 Low |

## Test cases

### TC-1 — Default build is silent and Orca-free · 🔴 Critical

The default build is what most boxes run. It must not mention a feature it does
not have. Run this **before** TC-2, on a clean volume.

**Steps**

1. Make sure `WITH_ORCA` is absent or `false` in `.env`.
2. Start from nothing:

```sh
docker compose down -v && docker compose up -d --build
```

3. Wait for the tailnet to come up, then read the whole log:

```sh
docker compose logs devaloy
```

**Expected**

- The log ends with `devaloy is up. Connect with: ssh dev@devaloy`.
- **No** mention of Orca anywhere — no warning, no "not installed", no skip
  notice. Silence is the pass condition here.
- No `WARNING` lines other than ones you already expect from a cold volume.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-2 — Cold boot with `WITH_ORCA=true` reaches a pairing URL · 🔴 Critical

**Steps**

1. Set `WITH_ORCA=true` in `.env`.
2. Rebuild from an empty volume, so this is a genuine cold boot:

```sh
docker compose down -v && docker compose up -d --build
```

3. Expect a long build — a 154 MB deb plus the Chromium libraries. Then watch
   the boot:

```sh
docker compose logs -f devaloy
```

4. Once it settles, pull out the pairing lines:

```sh
docker compose logs devaloy | grep -E "Orca server|Pairing URL|Web client URL"
```

**Expected**

- The Orca lines appear **after** the Tailscale line, not before — the server
  needs the tailnet address to advertise.
- A line reading `[entrypoint] Orca server on 100.x.y.z:6768 — pair a client
  with the URL`.
- `Orca server ready`, and `Bound endpoint: ws://0.0.0.0:6768`.
- `Advertised endpoint:` shows the box's **tailnet** address, not `0.0.0.0` and
  not a `192.168.*` or docker bridge address.
- A `Pairing URL: orca://pair?code=…` line.
- `Failed to connect to the bus` errors appear and are **harmless** — the server
  still reaches `ready`. Note roughly how many; a wall of them is a usability
  finding even though it is not a functional one.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-3 — Pair the Orca desktop app over the tailnet · 🔴 Critical

This is the case the whole feature exists for.

**Steps**

1. On the Mac, confirm Tailscale is connected and the box is visible.
2. Copy the full `orca://pair?code=…` URL from the log.
3. Open it with the Orca desktop app.
4. Once paired, browse the box's filesystem from the app and open a terminal in
   it.

**Expected**

- The app pairs without asking for a password or a key.
- The app shows devaloy as a **remote runtime**, and the box owns the session —
  projects and terminals live there, not on the Mac.
- A terminal opened in the app lands in the container as `dev`, and `pwd` and
  `whoami` agree with what an SSH session shows.
- Judge the flow: was the pairing URL findable from the docs alone? Note it if
  you had to guess.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-4 — An agent actually runs from the Orca client · 🔴 Critical

Binding a port proves very little. This is the case that catches a `PATH`
regression around `link-shims` — the failure mode is `spawn codex ENOENT`, and
it is invisible until an agent is actually launched.

**Steps**

1. In the paired desktop app, open a workspace on a real repo on the box.
2. Start a **Claude Code** session from the Orca client and give it a trivial
   task ("list the files in this directory").
3. Repeat with a **Codex** session.

**Expected**

- Both agents start. Neither reports `spawn codex ENOENT`, `spawn claude
  ENOENT`, or `command not found`.
- Both produce real output from the box's filesystem.
- Check the container log while they run:

```sh
docker compose logs --tail=50 devaloy
```

- No new `ENOENT` errors appear there either.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-5 — Pairings survive `down && up` — and rule on dbus · 🔴 Critical

This case does double duty. It proves the `$HOME/.config` state assumption, and
it is the **arbiter for the deferred dbus decision**: Electron's `safeStorage`
reaches for libsecret over a session bus, and there is none on this box.

**Steps**

1. With the desktop app paired and working, recreate the container — note this
   is `down`, **not** `down -v`, so the home volume survives:

```sh
docker compose down && docker compose up -d
```

2. Wait for the log to reach `Orca server ready`.
3. Return to the Orca desktop app without re-pairing anything.

**Expected**

- The desktop app reconnects **on its own**, with no new pairing URL entered.
- The projects and workspaces from TC-3 are still listed.
- If it does **not** reconnect, that is the dbus answer: record it as a failure
  here and the fix is adding `dbus-x11` plus wrapping the launch in
  `dbus-run-session`. Do not paper over it by re-pairing and calling it a pass.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-6 — Tailscale SSH and herdr still work unchanged · 🔴 Critical

Regression case. Orca is additive; the box's primary path and its recovery path
must be untouched by it.

**Steps**

1. From the Mac, with Orca running:

```sh
ssh dev@devaloy
```

2. Start a session:

```sh
herdr
```

3. Detach, reconnect from another device, and confirm the session resumed.
4. Check that the shell environment is intact — the toolchain resolves and the
   OOM reset applied:

```sh
which node claude codex && cat /proc/self/oom_score_adj
```

**Expected**

- SSH works with no key, no port flag, no password.
- `herdr` starts and reattaches as before.
- All three tools resolve.
- `/proc/self/oom_score_adj` reads `0` for the interactive shell — Orca's
  `-250` must not have leaked into login sessions.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-7 — `up -d` without `--build` silently changes nothing · 🟡 Normal

The docs call this the single most likely footgun. This case checks the docs
are telling the truth about it.

**Steps**

1. Set `WITH_ORCA=false` in `.env`.
2. Deliberately omit `--build`:

```sh
docker compose up -d
```

3. Read the log:

```sh
docker compose logs devaloy | grep -ci orca
```

**Expected**

- Orca is **still running** — the old image is still in use.
- No error and no warning about the changed value. The silence is the point:
  confirm the behaviour matches what the README warns about.
- Now do it properly and confirm it takes effect:

```sh
docker compose up -d --build
```

- After the rebuild, Orca is gone and the log is silent, as in TC-1.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-8 — Pair the phone, or establish what it needs · 🟡 Normal

**Treat this as an investigation, not a pass/fail on a known-good path.** The
documented method is unverified: `--mobile-pairing` is a flag on *the* server
rather than a second command, and a second `orca serve` in this container is
rejected by Electron's single-instance lock (confirmed — see
[Automated verification](#automated-verification-by-ai-agent)). So it is not
yet known whether the mobile app accepts the runtime-scoped code.

**Steps**

1. Connect Tailscale on the phone and confirm it can reach the box.
2. Get both artifacts the running server prints:

```sh
docker compose logs devaloy | grep -E "Pairing URL|Web client URL"
```

3. Try the `orca://pair?code=…` link on the phone first — AirDrop it, or paste
   it into a note and tap it.
4. If that fails, open the `Web client URL:` in the phone's browser.

**Expected**

- One of the two gets the phone connected to the box.
- Record **which one worked**, because the docs currently offer both without
  knowing.
- If neither works, record the exact error. The fallback is adding
  `--mobile-pairing` to the supervised launch in `entrypoint.sh` and rebuilding,
  at the cost of the desktop's default link — do not attempt that here, just
  report it.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-9 — The supervised restart loop actually restarts · 🟡 Normal

**Steps**

1. Kill the running server from inside the container:

```sh
docker compose exec devaloy pkill -f "orca-ide --serve"
```

2. Watch the log for about 30 seconds:

```sh
docker compose logs -f devaloy
```

**Expected**

- A `WARNING: orca serve exited — restarting in 10s` line appears.
- Roughly ten seconds later the server comes back and reaches ready again.
- The container itself does **not** exit — `wait` is on `tailscaled`, so SSH
  stays up throughout. Confirm you never lose your SSH session.
- Confirm the documented consequence too: because there is no runtime kill
  switch, `pkill` cannot make it stay down.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-10 — No tailnet means no server, and a warning that says so · 🟡 Normal

Advertising an address nothing can route to is worse than not starting, because
the failure surfaces at pairing time instead of in the log.

**Steps**

1. Stop the stack and destroy **both** volumes, so there is no saved node
   identity to fall back on:

```sh
docker compose down -v
```

2. Blank the auth key — comment out `TS_AUTHKEY` in `.env`.
3. Start it:

```sh
docker compose up -d
```

4. Read the log after the Tailscale timeout (~90s):

```sh
docker compose logs devaloy
```

**Expected**

- `WARNING: tailscale up failed` appears, as before this change.
- Then `WARNING: no tailnet IPv4 — not starting orca serve.` followed by the
  line telling you to fix Tailscale and restart.
- **No** Orca process is running, and nothing is listening on 6768.
- The container is still up, so the documented break-glass path still works:

```sh
docker compose exec devaloy tailscale up --ssh
```

5. Restore `TS_AUTHKEY` afterwards.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-11 — Port 6768 is reachable from the host, and nowhere else · 🟡 Normal

The compose comment makes a specific security claim. This checks it is accurate
in both directions.

**Steps**

1. From inside the OrbStack Linux machine (the Docker host), get the container's
   bridge IP and connect to it:

```sh
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' devaloy
```

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://<bridge-ip>:6768/
```

2. Confirm nothing is published to the host's own interfaces:

```sh
docker compose ps
```

3. From the Mac, off the tailnet — turn Tailscale **off** — try the tailnet
   address and confirm it is unreachable.

**Expected**

- Step 1 connects. This is the documented, accepted nuance: the port is
  reachable from the Docker host.
- Step 2 shows **no** published ports in the `PORTS` column.
- Step 3 fails to connect with Tailscale off, confirming the tailnet is still
  the only remote way in.
- Turn Tailscale back on afterwards.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-12 — The on-box agent check command tells the truth · 🟢 Low

`CLAUDE.md` and `AGENTS.md` now tell the on-box agents to *check* for a runtime
rather than assume. The check has to actually work on both builds.

**Steps**

1. SSH in on the `WITH_ORCA=true` build and run the documented check:

```sh
command -v orca-ide && pgrep -f "orca-ide.*serve" >/dev/null && echo "runtime up"
```

2. Ask Claude Code (or Codex) on the box whether `orca-cli` can work here.

**Expected**

- Step 1 prints a path and `runtime up`.
- The agent checks rather than asserting from memory, and answers correctly.
- On a `WITH_ORCA=false` build the same command prints nothing and the agent
  says `orca-cli` is inert here.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-13 — Orca dies before `tailscaled` under memory pressure · 🟢 Low

The OOM ordering is verified statically ([Automated
verification](#automated-verification-by-ai-agent)); what is not verified is the
kernel honouring it under real pressure. This is a **proxy** test — a laptop VM
is not a loaded VPS.

**Steps**

1. Confirm the live values first:

```sh
docker compose exec devaloy sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline); case "$c" in *orca-ide*|*tailscaled*) echo "$(cat $p/oom_score_adj)  $(echo $c | cut -c1-40)";; esac; done'
```

2. Optionally, cap the VM's memory low and run a deliberately memory-hungry
   build in an SSH session.

**Expected**

- `tailscaled` reads `-500`; the Orca processes read `-250`.
- One exception is expected and correct: Chromium's own **GPU process** sets
  itself to `200` so it is sacrificed first. That is Chromium's behaviour, not a
  bug in this change.
- Under pressure, the runaway build should die before Orca, and Orca before
  `tailscaled` — you should never lose SSH first.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

## Regression checks

- [ ] `docker compose up -d --build` with no `.env` changes still works on the
      default build.
- [ ] The `dev` user's shell is still `zsh`, and `~/.zshrc` still comes from the
      repo.
- [ ] `devaloy-update` still runs and still reports the toolchain.
- [ ] `config/` dotfiles still land in `/home/dev` on boot, and hand-added files
      are still left alone.
- [ ] `GITHUB_TOKEN` still authenticates `gh` on the Orca build.
- [ ] The home volume still survives `docker compose down && up`.

## Automated verification (by AI agent)

_Checks the agent ran itself — no action needed from the tester; listed here for
context and sign-off._

```sh
shellcheck entrypoint.sh bootstrap-toolchain.sh devaloy-update link-shims
```

```sh
bash -n entrypoint.sh
```

```sh
docker compose config
```

```sh
docker build -t devaloy:qa-default .
```

```sh
docker build --build-arg WITH_ORCA=true -t devaloy:qa-orca .
```

```sh
docker run --rm --entrypoint sh devaloy:qa-orca -c 'stat -c "%a" /opt/Orca/chrome-sandbox; readlink -f /usr/bin/orca-ide; ldd /opt/Orca/orca-ide | grep -c "not found"'
```

```sh
docker run --rm --entrypoint /usr/bin/orca-ide devaloy:qa-orca serve --help
```

```sh
docker run --rm --oom-score-adj -500 --entrypoint sh devaloy:qa-orca -c '( echo -250 > /proc/self/oom_score_adj; su -l -s /bin/sh dev -c "cat /proc/self/oom_score_adj" )'
```

Results:

- ✅ `shellcheck` on all four scripts → clean, no warnings.
- ✅ `bash -n entrypoint.sh` → parses.
- ✅ `docker compose config` → valid, and `WITH_ORCA: "false"` resolves under
  `build.args`, confirming the default and the `.env` wiring.
- ✅ Both builds succeed → `devaloy:qa-default` 683 MB, `devaloy:qa-orca` 1.6 GB.
  The plan's "~540 MB / roughly triples" estimate was wrong; every doc now
  carries the measured numbers.
- ✅ Default image → `/opt/Orca` absent and `/usr/bin/orca-ide` absent, so the
  entrypoint's guard short-circuits and TC-1's silence is structural.
- ✅ Orca image → `chrome-sandbox` is `4755` (set by the deb's own `postinst`),
  `/usr/bin/orca-ide` resolves to `/opt/Orca/resources/bin/orca-ide`, and
  `ldd` reports **0** missing libraries.
- ✅ `serve --help` → `--port`, `--pairing-address`, `--mobile-pairing` all exist
  as the implementation assumes.
- ✅ OOM propagation → a container starting at `-500` runs a `su -l -s /bin/sh`
  child at `-250`, so the entrypoint's wrapper does reach the real process.
- ✅ Live process tree under a real `orca serve` → `xvfb-run`, the launcher, the
  serve main and every zygote all at `-250`. Chromium's GPU process sits at
  `200` by its own design.
- ✅ Headless smoke test → `Orca server ready`, `Bound endpoint:
  ws://0.0.0.0:6768`, `Advertised endpoint:` honouring `--pairing-address`, a
  `Pairing URL:`, and `ss -ltn` showing `LISTEN 0.0.0.0:6768`.
- ✅ dbus errors (8 of them) appear and the server still reaches ready →
  cosmetic at the server level, as the plan predicted. Whether they cost
  *pairing persistence* is TC-5's job, not something this can settle.
- ❌ **A second `orca serve` cannot run alongside the supervised one.** Actual
  output:

```
[single-instance] Another Orca instance is already running for this userData
profile; exiting this launch after requesting the existing window.
```

  This invalidated the mobile-pairing instructions originally written into the
  README and the wiki page. Both were corrected before this plan was written,
  and TC-8 is now framed as an investigation rather than a known-good path.
  There is no `orca pair` subcommand — confirmed against the CLI's own
  top-level help.

## Not covered / needs human judgment

- **The `amd64` path is entirely unexercised.** Every check above ran on arm64.
  The arch is read from `dpkg --print-architecture` and upstream ships both
  debs, but no x86 build has been done — this is the largest untested surface,
  and it is the one a VPS deployment would hit first.
- **Whether the mobile app pairs at all** (TC-8). The originally documented
  method is disproven; the replacement is a hypothesis. This is the single
  biggest open question in the feature, and the plan's own success criteria
  named mobile as the reason the whole thing exists.
- **Whether pairings actually survive a redeploy** (TC-5). The state assumption
  is untested — nothing has yet paired and come back. The dbus decision rides
  entirely on it.
- **Real memory pressure** (TC-13). The OOM ordering is proven statically; the
  kernel honouring it while a build, several agents and an Electron runtime
  compete has not been observed.
- **The autoupdater's behaviour when an update exists.** It was pinned at
  1.4.164 and the smoke tests were short. Nobody has seen what happens when a
  newer release is actually available — whether it fails loudly against
  root-owned `/opt` or quietly downloads ~160 MB into the home volume. Accepted
  as a known unknown during grilling; still unknown.
- **Sustained uptime.** Longest observed run is under two minutes. Leaks,
  file-descriptor growth, and whether the restart loop ever thrashes over days
  are all unobserved.
- **Two servers on one tailnet.** Guarded by a doc line and the default-off
  build, not by anything in the code. Not tested, and testing it means
  deliberately building a second box `WITH_ORCA=true`.
- **Whether Orca's own Chromium tempts anyone into using it for `verifykit`.**
  An explicit non-goal, unenforced by anything but the docs.
- **Build time on a slower link.** The build pulls 154 MB plus the Chromium
  library set; timings here came from a fast connection.

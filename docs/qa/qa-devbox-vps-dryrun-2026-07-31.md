# QA Plan: devaloy devbox — full VPS dry run

_Generated 2026-07-31 · rewritten same day for the merged Tailscale SSH design
(single container, no sshd, no SSH keys) · covers Dockerfile, entrypoint.sh,
compose.yml, bootstrap-toolchain.sh, devaloy-update, link-shims,
scripts/host-firewall-lockdown.sh_

_Design of record: [`docs/plans/plan-remote-devbox-2026-07-25.md`](../plans/plan-remote-devbox-2026-07-25.md),
Revision 2026-07-31._

## Summary

- A single-container devbox reachable **only** through Tailscale SSH — no sshd,
  no `authorized_keys`, no published ports — exercised end to end against a
  throwaway Ubuntu VM standing in for a real VPS.
- "Working" means: the node joins your tailnet, `ssh dev@devbox` succeeds from a
  Mac and a phone with **no key material anywhere**, the box carries a working
  toolchain plus Claude Code and Codex, and it survives a redeploy with the
  session and node identity intact.

## Preconditions

**On the Mac**

- OrbStack running (`orb version` ≥ 2.2.1).
- A Tailscale account with the Mac already on the tailnet.
- MagicDNS enabled, or you're prepared to use the raw `100.x.y.z` address
  everywhere `devbox` appears below.
- Admin access to your [tailnet policy file](https://login.tailscale.com/admin/acls)
  — TC-2 edits it, and nothing after TC-2 works without that edit.

**On the phone**

- The Tailscale app, signed into the same tailnet.
- Terminus (iOS/Android).

**No SSH keys are needed anywhere in this plan.** That is the point of the
design. If you find yourself generating a keypair, something has gone wrong.

**Two lockout risks to know before you start**

- **Key expiry.** The devbox registers as a *user-owned* node, and user-owned
  node keys expire (~180 days by default). An expired node is unreachable.
  TC-5 disables expiry; do not skip it.
- **No sshd fallback.** If Tailscale SSH won't let you in, there is no second
  door. The break-glass path is the Docker host (`docker compose exec`), which
  TC-16 exercises deliberately so you know it works *before* you need it.

**Teardown, for reference.** `docker compose down` keeps your volumes;
`docker compose down -v` destroys the home volume **and the Tailscale node
identity**, forcing a re-register. Never use `-v` mid-plan.

## Test cases at a glance

Priority legend: 🔴 Critical · 🟡 Normal · 🟢 Low

| # | Test case | Priority |
|------|-----------|----------|
| TC-1 | Provision the Ubuntu "VPS", install Docker, load `tun` | 🔴 Critical |
| TC-2 | Add the Tailscale SSH rule to the tailnet policy file | 🔴 Critical |
| TC-3 | Clone the repo and configure `.env` | 🔴 Critical |
| TC-4 | First boot — build and start the stack | 🔴 Critical |
| TC-5 | The node joins the tailnet — and disable key expiry | 🔴 Critical |
| TC-6 | Tailscale SSH in from the Mac, with no keys at all | 🔴 Critical |
| TC-7 | The toolchain is present and pinned | 🔴 Critical |
| TC-8 | Non-interactive sessions and file transfer see the toolchain | 🔴 Critical |
| TC-9 | Install and authenticate Claude Code | 🟡 Normal |
| TC-10 | Install and authenticate Codex | 🟡 Normal |
| TC-11 | Connect from the phone with Terminus | 🔴 Critical |
| TC-12 | herdr session survives a device handoff | 🔴 Critical |
| TC-13 | Real work: clone, build, commit from the devbox | 🟡 Normal |
| TC-14 | Redeploy preserves home, node identity and session | 🔴 Critical |
| TC-15 | Access control actually denies what it should | 🔴 Critical |
| TC-16 | Break-glass recovery from the Docker host | 🟡 Normal |
| TC-17 | `devaloy-update` refreshes toolchain and shims | 🟢 Low |
| TC-18 | Host firewall lockdown refuses to lock you out | 🟢 Low |

---

## Test cases

### TC-1 — Provision the Ubuntu "VPS", install Docker, load `tun` · 🔴 Critical

Pinning `noble` gives you Ubuntu 24.04, matching what a real VPS ships; a bare
`orb create ubuntu` currently lands on 26.04.

**Steps**

1. Create the machine:

```sh
orb create ubuntu:noble devaloy-vps
```

2. Open a shell on it — every step marked *(on the VPS)* runs here:

```sh
orb -m devaloy-vps
```

3. *(on the VPS)* Install Docker:

```sh
curl -fsSL https://get.docker.com | sudo sh
```

4. *(on the VPS)* Grant daemon access without `sudo`, then re-open the shell so the group takes effect:

```sh
sudo usermod -aG docker "$USER" && exit
```

5. *(on the VPS)* Confirm the `tun` device exists — the container needs it, and `SYS_MODULE` is deliberately not granted so it cannot load the module itself:

```sh
ls -l /dev/net/tun || sudo modprobe tun
```

6. Confirm Docker:

```sh
orb -m devaloy-vps docker version --format '{{.Server.Version}}'
```

**Expected**

- `orb list` shows `devaloy-vps` as `running`, `ubuntu`, `noble`.
- `/dev/net/tun` exists (`crw-rw-rw- ... 10, 200`).
- Docker reports a server version (29.x at time of writing) with no permission error.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-2 — Add the Tailscale SSH rule to the tailnet policy file · 🔴 Critical

**This is new setup that did not exist in the old key-based design.** Tailscale
SSH is deny-by-default: without this rule the node joins the tailnet happily and
you still cannot log in. Do it *before* first boot so TC-6 is a clean test.

**Steps**

1. Open https://login.tailscale.com/admin/acls
2. Add an `ssh` section (merge it with any existing rules rather than replacing them):

```json
{
  "ssh": [
    {
      "action": "accept",
      "src":    ["autogroup:member"],
      "dst":    ["autogroup:self"],
      "users":  ["dev"]
    }
  ]
}
```

3. Save, and confirm the policy file validates without error.

**Expected**

- The policy saves cleanly with no syntax error.
- The rule reads `dst: autogroup:self` — meaning devices owned by the same user
  as the connecting device. This is why TC-3's auth key must be **untagged**; a
  tagged node has no user owner and `autogroup:self` will never match it.
- `users` is `["dev"]` only — root is not listed, which TC-15 verifies.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-3 — Clone the repo and configure `.env` · 🔴 Critical

**Steps**

1. *(on the VPS)* Clone over HTTPS:

```sh
git clone https://github.com/mimukit/devaloy.git ~/devaloy && cd ~/devaloy
```

2. Generate a **reusable, non-expiring, UNTAGGED** auth key at
   https://login.tailscale.com/admin/settings/keys
   Leaving it untagged is what makes the node user-owned, which is what
   TC-2's `autogroup:self` rule requires.

3. *(on the VPS)* Seed the env file:

```sh
cp .env.example .env
```

4. **Read `.env.example` yourself before going further.** No agent in this
   project has ever been able to read this file — it is blocked by permission
   settings — and it is public on GitHub. Confirm it holds placeholders only.

```sh
cat .env.example
```

5. *(on the VPS)* Set `TS_AUTHKEY` in `.env`:

```sh
nano .env
```

6. Confirm compose resolves it:

```sh
docker compose config | grep TS_AUTHKEY
```

**Expected**

- `.env.example` contains only placeholders — no live auth key.
- There is **no** `PUBLIC_KEY` variable anywhere. If you see one, `.env.example`
  is stale relative to the merged design and needs updating.
- `docker compose config` prints the key populated, with no blank-variable warning.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-4 — First boot: build and start the stack · 🔴 Critical

**Steps**

1. *(on the VPS)* Build and start:

```sh
docker compose up -d --build
```

2. Watch the log — the tailnet comes up first, then the toolchain installs over several minutes:

```sh
docker compose logs -f devbox
```

3. Press Ctrl-C once you see `devaloy is up`, then check the container:

```sh
docker compose ps
```

**Expected**

- The log order is: `Starting tailscaled` → `Tailscale SSH is up as devbox (100.x.y.z)` → `Bootstrapping mise + toolchain` → `Toolchain bootstrap complete` → `devaloy is up`.
- The tailnet line comes **before** the bootstrap — the box is reachable during the slow install, not after it.
- **No** `WARNING: tailscale up failed`. If you see it, the box is unreachable; go to TC-16.
- **No** `WARNING: toolchain bootstrap failed`. If you see it the box is still reachable by design — note it, carry on, and use `devaloy-update` (TC-17) to recover.
- Exactly one container, `devaloy-devbox`, `running` (not restarting).
- `docker compose ps` shows **no port mappings at all**.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-5 — The node joins the tailnet, and disable key expiry · 🔴 Critical

**Steps**

1. Open https://login.tailscale.com/admin/machines
2. Find the newly-registered `devbox`.
3. **Disable key expiry on it** (machine menu → Disable key expiry). This is not optional — see Preconditions.
4. *(on the VPS)* Cross-check what the container believes:

```sh
docker compose exec devbox tailscale status
```

**Expected**

- A machine named exactly `devbox` appears and is connected.
- Its name is **not** `devbox-1` — a suffix means a name collision with an existing machine and every hostname below resolves to the wrong host.
- It is listed as owned by **you**, not as a tagged node. A tagged node means the key was tagged and TC-2's rule will never match.
- Key expiry now reads **Disabled**.
- `tailscale status` shows the node as `Running` and lists `dev@` as an SSH-enabled service (or otherwise indicates SSH is advertised).

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-6 — Tailscale SSH in from the Mac, with no keys at all · 🔴 Critical

The headline test. Note there is no `-p 2222` and no `-i <key>`: Tailscale SSH
assumes port 22 and authenticates from tailnet identity.

**Steps**

1. **On the Mac** (not the VPS):

```sh
ssh dev@devbox
```

2. Confirm who and where you are:

```sh
whoami && hostname && sudo -n true && echo "passwordless sudo OK"
```

3. Confirm this really is the devbox container and not something else:

```sh
cat /etc/os-release | head -2 && ls /home/dev
```

**Expected**

- The connection succeeds with **no key prompt, no password prompt, and no host-key fingerprint prompt**.
- It greets you with `devaloy devbox — run: herdr`.
- `whoami` is `dev`; `hostname` is `devbox`; passwordless sudo works.
- `/etc/os-release` says Ubuntu 24.04 — **not** Alpine. Alpine would mean you
  landed in a Tailscale sidecar, which is the exact failure this design exists
  to avoid.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-7 — The toolchain is present and pinned · 🔴 Critical

**Steps**

1. From the SSH session on the devbox:

```sh
node -v && pnpm -v && gh --version && turbo --version && herdr --version
```

2. Confirm they resolve through mise's shims:

```sh
command -v node pnpm gh turbo herdr
```

**Expected**

- `node -v` prints `v24.x` — the LTS major pinned in `bootstrap-toolchain.sh`.
- All five print a version rather than `command not found`.
- Interactive paths resolve under `/home/dev/.local/share/mise/shims/`.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-8 — Non-interactive sessions and file transfer see the toolchain · 🔴 Critical

The highest-risk case in this plan. Bash only auto-sources `.bashrc` in a
non-interactive shell when stdin is a *socket* — an OpenSSH implementation
detail we no longer depend on now that sshd is gone. `link-shims` mirrors the
toolchain into `/usr/local/bin` to cover this. Verified working under `docker
exec`; **unverified under Tailscale SSH specifically.**

**Steps**

1. **On the Mac**, run a command remotely with no TTY:

```sh
ssh dev@devbox 'node -v && pnpm -v && echo $PATH'
```

2. Confirm SCP works (Tailscale implements SFTP natively, so modern clients should be fine):

```sh
echo hello > /tmp/devaloy-probe.txt && scp /tmp/devaloy-probe.txt dev@devbox:~/
```

3. Confirm rsync works:

```sh
rsync /tmp/devaloy-probe.txt dev@devbox:~/probe2.txt
```

4. Confirm sftp connects:

```sh
sftp dev@devbox
```

**Expected**

- Step 1 prints both versions — **not** `node: command not found`.
- `$PATH` contains `/usr/local/bin`, and `node` resolves there even if the mise shim path is absent.
- Step 1 does **not** print the `devaloy devbox — run: herdr` banner; leaking it would corrupt scp/rsync.
- Steps 2–4 all succeed.
- **If step 1 fails** but TC-7 passed, `link-shims` did not cover this path. Recovery, then re-test:

```sh
ssh dev@devbox 'sudo DEV_HOME=/home/dev link-shims'
```

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-9 — Install and authenticate Claude Code · 🟡 Normal

The native installer targets `~/.local/bin`, which `.devaloy_env` already puts
first on `PATH`.

**Steps**

1. On the devbox:

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

2. Confirm it landed:

```sh
command -v claude && claude --version
```

3. Start it and work through the login prompts:

```sh
claude
```

4. This box is headless. Copy the URL it prints, open it on the Mac, paste the
   code back. If it insists on a local callback port, reconnect with that port
   forwarded and retry:

```sh
ssh -L 54545:localhost:54545 dev@devbox
```

5. Once authenticated, give it a trivial task:

```sh
claude -p "list the files in this directory and say what this project is"
```

**Expected**

- `claude --version` prints a version from `/home/dev/.local/bin/claude`.
- The login completes over copy-paste alone, without a browser on the box.
- Auth persists across a reconnect.
- Step 5 returns a sensible answer, confirming outbound API access works.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-10 — Install and authenticate Codex · 🟡 Normal

Verified separately: `npm i -g` under mise auto-reshims, so no manual `mise
reshim` is needed. You **do** need `devaloy-update` (or `link-shims`) afterwards
for non-interactive sessions to see it.

**Steps**

1. On the devbox:

```sh
npm i -g @openai/codex
```

2. Confirm it resolved:

```sh
command -v codex && codex --version
```

3. Codex's browser login uses a callback on `localhost:1455`, which does not exist on a headless box. Reconnect **from the Mac** with that port forwarded:

```sh
ssh -L 1455:localhost:1455 dev@devbox
```

4. In that forwarded session, log in — open the printed URL in the Mac's browser:

```sh
codex login
```

5. If the browser flow proves unworkable, fall back to an API key and note that you had to:

```sh
codex login --api-key
```

6. Mirror the new binaries so non-interactive sessions see them:

```sh
sudo DEV_HOME=/home/dev link-shims
```

7. Give it a trivial task:

```sh
codex exec "summarize what this repository does"
```

**Expected**

- `command -v codex` resolves with no manual `mise reshim`.
- The forwarded-port login completes.
- After step 6, `ssh dev@devbox 'codex --version'` works from the Mac.
- Step 7 returns a sensible answer.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-11 — Connect from the phone with Terminus · 🔴 Critical

**The biggest unknown in this plan.** Tailscale SSH accepts connections with no
client key — the SSH client must be willing to proceed with the `none`
authentication method. OpenSSH does this. Whether Terminus does is untested.

**Steps**

1. On the phone, open the Tailscale app and confirm it is connected.
2. Confirm `devbox` shows as online in the app's machine list.
3. In Terminus, create a new host:
   - **Hostname** `devbox` (if it fails to resolve, use the `100.x.y.z` from TC-5 — MagicDNS is unreliable on mobile)
   - **Port** `22` (not 2222 — that is gone)
   - **Username** `dev`
   - **Key / auth** — leave empty. Do not attach a key.
4. Connect.
5. Confirm identity and toolchain:

```sh
whoami && node -v
```

6. Turn Tailscale **off** on the phone and try again.

**Expected**

- The connection succeeds with no key and no password prompt.
- If Terminus refuses to connect without an auth method, note the exact error —
  that is a genuine finding against this design, and the fallback is to reinstate
  an sshd alongside Tailscale SSH.
- `whoami` is `dev`; `node -v` prints v24.x.
- Text is legible and the terminal usable at phone size — judge whether you'd actually work in this.
- With Tailscale off, the connection **fails**. This is the core security assertion.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-12 — herdr session survives a device handoff · 🔴 Critical

The whole point of the project — judge it as a user, not a checklist.

**Steps**

1. From the **Mac** session:

```sh
herdr
```

2. Inside it, start something long-running and visibly stateful:

```sh
python3 -c "import time,itertools; [print(f'tick {i}') or time.sleep(2) for i in itertools.count()]"
```

3. Close the Mac terminal window outright — don't detach cleanly. This simulates a lid closing.
4. On the **phone** in Terminus, reattach:

```sh
herdr
```

5. Watch for a minute, then reattach from the Mac with the phone still connected.

**Expected**

- The phone picks up the *same* session — the counter kept advancing during the gap, it did not restart from zero.
- No output lost or duplicated at the handoff.
- Reattaching from the Mac works, or gives a clear message about the existing attachment — either is acceptable, note which.
- Judge the reattach latency: usable for real work, or annoying?

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-13 — Real work: clone, build, commit from the devbox · 🟡 Normal

**Steps**

1. On the devbox, authenticate `gh`:

```sh
gh auth login
```

2. Clone a real project and install its deps:

```sh
gh repo clone mimukit/devaloy ~/work-devaloy && cd ~/work-devaloy
```

3. Make a trivial commit:

```sh
git commit --allow-empty -m "test(repo): devbox connectivity check" && git log -1
```

4. Do **not** push. Delete the clone afterwards.
5. Judge the experience: run `vim`, run `htop`, see how the box feels under load.

**Expected**

- `gh auth login` completes over the copy-paste flow.
- The clone succeeds — outbound network works.
- The commit is created with a sane author identity, or git tells you clearly to set one.
- The box feels responsive over the tailnet.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-14 — Redeploy preserves home, node identity and session · 🔴 Critical

**Steps**

1. Leave a herdr session running and drop a marker, then disconnect:

```sh
echo "survived $(date)" > ~/marker.txt
```

2. *(on the VPS)* Redeploy — note the absence of `-v`:

```sh
docker compose down && docker compose up -d --build
```

3. Read the log:

```sh
docker compose logs devbox | tail -20
```

4. **From the Mac**, reconnect:

```sh
ssh dev@devbox
```

5. Check what survived:

```sh
cat ~/marker.txt && node -v && command -v claude codex
```

**Expected**

- The log shows `mise toolchain already bootstrapped, skipping` — the redeploy takes seconds, not minutes.
- The node keeps the **same** tailnet IP and does **not** re-register. Check the admin console for a stray `devbox-1`.
- No host-key warning on reconnect.
- `marker.txt` intact; node still v24.x; `claude` and `codex` still installed and still authenticated.
- Your herdr session is still there (`herdr` reattaches to it) even though tailscaled restarting drops the SSH connection itself.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-15 — Access control actually denies what it should · 🔴 Critical

Your stated requirement is that the box is unreachable except via Tailscale SSH.
This is the case that proves it.

**Steps**

1. **From the Mac**, try to log in as a user the ACL does not permit:

```sh
ssh root@devbox
```

2. *(on the VPS)* Confirm nothing is listening on the host's own interfaces:

```sh
docker compose ps && sudo ss -tlnp | grep -E ':22|:2222' || echo "nothing on 22/2222"
```

3. **From the Mac**, try to reach the VPS directly on its LAN address rather than its tailnet address — substitute the IP from `orb list`:

```sh
nc -vz -w 5 192.168.x.x 22
```

4. Temporarily remove the `ssh` rule from the policy file, save, and retry from the Mac:

```sh
ssh dev@devbox
```

5. Restore the rule.

**Expected**

- Step 1 is **denied** — `users: ["dev"]` does not include root.
- Step 2 shows no container port mappings, and nothing of ours listening on the host's 22/2222 (the host's own sshd on 22 is fine and expected).
- Step 3 does **not** reach the devbox. Any devbox shell here is a blocker.
- Step 4 is **denied** — proving the policy file, not the network, is what grants access.
- After step 5, access works again.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-16 — Break-glass recovery from the Docker host · 🟡 Normal

There is no sshd fallback. Prove the recovery path works *before* you need it.

**Steps**

1. *(on the VPS)* Simulate a broken tailnet by logging the node out:

```sh
docker compose exec devbox tailscale logout
```

2. **From the Mac**, confirm you are now locked out:

```sh
ssh dev@devbox
```

3. *(on the VPS)* Recover:

```sh
docker compose exec devbox tailscale up --ssh
```

4. Follow the printed URL to re-authenticate, then retry from the Mac.

**Expected**

- Step 2 fails — no route to host, or connection refused.
- Step 1 and 3 work from the host even with the tailnet down, because `docker compose exec` does not go through Tailscale.
- After step 4 you are back in, and the node reappears in the admin console.
- Note whether it came back with the same IP or a new one.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-17 — `devaloy-update` refreshes toolchain and shims · 🟢 Low

**Steps**

1. On the devbox, as `dev`:

```sh
devaloy-update
```

2. Confirm it refuses to run as root:

```sh
sudo devaloy-update
```

3. Re-check the toolchain, and that non-interactive access still works:

```sh
node -v && herdr --version
```

**Expected**

- The `dev` run ends with `devaloy: toolchain updated.` and a `link-shims: linked N tool(s)` line.
- The `sudo` run exits immediately with `devaloy-update: run this as the dev user, not root.`
- Node is still on the pinned v24 major — an update must not jump majors.
- Any herdr session you had open is unaffected.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-18 — Host firewall lockdown refuses to lock you out · 🟢 Low

Run this **last**. It hardens the VPS host and is the one step that can cut your
own access to the host.

**Steps**

1. *(on the VPS, via `orb -m devaloy-vps`)* Try it before Tailscale is on the host:

```sh
sudo ./scripts/host-firewall-lockdown.sh
```

2. Install Tailscale on the VPS host itself:

```sh
curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up
```

3. Retry:

```sh
sudo ./scripts/host-firewall-lockdown.sh
```

4. Confirm:

```sh
sudo ufw status verbose
```

**Expected**

- Step 1 refuses with `Tailscale is not up on this host — refusing to lock down (anti-lockout guard).` and changes nothing.
- Step 3 completes, or refuses with the non-tailnet-source guard — both are correct; note which fired.
- `ufw status verbose` shows incoming denied by default, an allow rule on `tailscale0`, and no 80/443.
- **Crucially:** you can still reach the devbox from the Mac afterwards. The container's tailnet is independent of the host firewall.
- Note that the host now has its own `devbox`-adjacent Tailscale node — don't confuse it with the container's.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

## Regression checks

- [ ] `git`, `tmux`, `vim`, `htop` and `build-essential` (try `gcc --version`) are present from the base image.
- [ ] `docker compose exec devbox cat /proc/1/oom_score_adj` prints `-500`, and `cat /proc/self/oom_score_adj` in an SSH session prints `0`.
- [ ] There is no `sshd` process in the container: `docker compose exec devbox pgrep sshd` finds nothing.
- [ ] There is no `/home/dev/.ssh/authorized_keys` and no `host_keys` directory — leftovers would mean a stale volume from the old design.
- [ ] `ssh dev@devbox 'echo $PATH'` includes `/usr/local/bin`.
- [ ] After a full `down && up`, the admin console still shows exactly one `devbox`.

## Automated verification (by AI agent)

_Checks the agent ran on the Mac before writing this plan — no action needed from the tester._

Static checks:

```sh
shellcheck entrypoint.sh bootstrap-toolchain.sh devaloy-update link-shims scripts/host-firewall-lockdown.sh
```

```sh
TS_AUTHKEY=dummy docker compose config
```

Image build and live container run (no auth key, so everything up to the tailnet join):

```sh
docker build -t devaloy-devbox:merged .
```

```sh
docker run -d --name devaloy-noauth --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun devaloy-devbox:merged
```

```sh
docker exec -u dev devaloy-noauth node -v
```

Environment-capability probe — a throwaway OrbStack machine, created, tested and deleted:

```sh
orb -m devaloy-probe sudo docker run --rm --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun alpine sh -c 'ip link add dummy0 type dummy && echo NET_ADMIN OK'
```

Results:

- ✅ `shellcheck` on all five scripts → exit 0, zero warnings.
- ✅ `docker compose config` → valid; one service, `NET_ADMIN` only, `/dev/net/tun` mapped, **no port mappings**, both volumes declared.
- ✅ Image builds on `ubuntu:24.04` → Tailscale **1.98.10** installed from the official noble apt repo.
- 🐞 **Bug found and fixed during this pass.** With no `TS_AUTHKEY` and no saved
  state, `tailscale up` prints a login URL and **blocks forever** — the entrypoint
  wedged before the toolchain bootstrap ever ran (confirmed: `/home/dev/.local`
  did not exist after 45s). Fixed by adding `--timeout=90s` to `tailscale up`;
  re-verified below.
- ✅ After the fix, the full boot sequence completes: `Starting tailscaled` → `WARNING: tailscale up failed` (expected, no key) → `Bootstrapping mise + toolchain` → `Toolchain bootstrap complete` → `devaloy is up`. Container stays alive.
- ✅ The non-fatal failure path works: with `/dev/net/tun` absent, tailscaled exits, the warnings fire, and **the bootstrap still runs**. A broken tailnet does not stop the box from building itself.
- ✅ Toolchain from a cold volume → node **v24.18.1** (matches the pin), pnpm **11.18.0**, herdr **0.7.5**, plus gh and turbo.
- ✅ `link-shims` mirrored 12 tools into `/usr/local/bin` and correctly **refused to clobber** the three real scripts already there (`bootstrap-toolchain.sh`, `devaloy-update`, `link-shims`).
- ✅ **Non-interactive resolution works**: `docker exec -u dev devaloy-noauth node -v` → `v24.18.1` with no shell init files sourced at all. This is the closest proxy available for Tailscale SSH's exec path (TC-8).
- ✅ `.bashrc` wiring correct: `.devaloy_env` is line 1 (above Ubuntu's interactivity guard), `.devaloy_profile` is the last line.
- ✅ Interactive shell resolves `node` via the mise shim path; non-interactive resolves via `/usr/local/bin`. Both mechanisms working in their own lane.
- ✅ Nested Docker in an OrbStack machine supports everything needed → Docker **29.7.0**, Compose **v5.3.1**, `NET_ADMIN` + `/dev/net/tun` confirmed, `--oom-score-adj -500` honored.
- ✅ `npm i -g @openai/codex` under mise auto-reshims — no manual `mise reshim`. TC-10 relies on this.
- ✅ All test containers and images removed; `orb list` back to its prior state.

**Notable finding, folded into TC-1:** a fresh OrbStack Ubuntu machine has **no**
`docker` binary and no shim to the host engine. Docker must be installed inside
the machine, which is what makes it a faithful VPS stand-in.

## Not covered / needs human judgment

- **Everything requiring a live tailnet.** No auth key was used, so the actual
  tailnet join, Tailscale SSH itself, MagicDNS, and every ACL assertion
  (TC-2, TC-5, TC-6, TC-15) are entirely unverified. The design rests on them.
- **Terminus compatibility (TC-11) is the single biggest risk.** Tailscale SSH
  needs a client willing to proceed with the `none` auth method. OpenSSH does;
  Terminus is untested. If it refuses, the merged design fails its main use case
  and the fallback is reinstating sshd alongside Tailscale SSH.
- **Non-interactive PATH under Tailscale SSH (TC-8).** Verified under `docker
  exec`, not under tailscaled's exec path. `link-shims` exists specifically
  because bash's `.bashrc` auto-sourcing depends on an OpenSSH detail that no
  longer applies. TC-8 carries an inline recovery command.
- **`.env.example` has never been read or written by any agent in this project**
  — blocked by permission settings on both Read and Bash. It still describes the
  old key-based design and **must be updated by hand** before TC-3 will make
  sense.
- **Claude Code and Codex install/auth specifics** are from prior knowledge, not
  a run. Expect to adapt the commands; consider adding whatever works to
  `bootstrap-toolchain.sh` so it survives a volume rebuild.
- **Mobile UX** — legibility, keyboard, reattach latency, whether you'd genuinely
  work this way. Cannot be scripted.
- **OOM behavior under real pressure.** The regression check reads configured
  values; it does not exhaust memory. Deliberately not scripted.
- **Real network conditions** — cellular, roaming, packet loss. Exactly what
  herdr exists for, and exactly what a same-host OrbStack VM cannot simulate.
- **Key expiry, multi-day persistence, host reboots** are out of scope for a
  single-session pass. TC-5's expiry toggle is the mitigation, untested over time.
- **Security posture change.** `NET_ADMIN` and `/dev/net/tun` now sit on the
  container that runs your agents and arbitrary npm packages, where the old
  sidecar kept them isolated. `SYS_MODULE` was dropped to limit the blast radius,
  but this is strictly weaker isolation than the two-container design.
- **Dokploy compatibility** (plan Phase 2) is untouched — though the merged
  design removes `network_mode: service:tailscale`, which was the specific
  feature in doubt. It may now be *more* deployable, unverified.

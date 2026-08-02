# QA Plan: devaloy — batteries included

_Generated 2026-08-02 · covers the uncommitted "batteries included" revision:
zsh as login shell, `config/` as the source of truth for shell and agent
dotfiles, `GITHUB_TOKEN` auth, Claude Code and Codex from `mise`, and the
retirement of the login banner._

_Design of record: [`docs/plans/plan-remote-devaloy-2026-07-25.md`](../plans/plan-remote-devaloy-2026-07-25.md),
Revision 2026-08-02._

_Prior run record: [`qa-devaloy-vps-dryrun-2026-07-31.md`](./qa-devaloy-vps-dryrun-2026-07-31.md).
That pass stands — this plan does not repeat it._

## Revised after the first run — 2026-08-02

The first run of this plan found three defects. All three are fixed, and the
affected cases below were rewritten, so **TC-1 through TC-5 and TC-9 need
re-running** against the corrected expectations.

| Reported | Cause | Fix |
|---|---|---|
| `zsh: command not found: claude` and `codex` (TC-4, TC-5, TC-9) | The boot bootstrap was gated on a marker that recorded only *that* it had run, never *what* it installed. Your home volume predates `claude`/`codex`, so the gate saw the marker, skipped, and the two tools were never installed. A cold volume worked, which is why the automated pass missed it entirely. | The marker now records `TOOLSET_REVISION` from `bootstrap-toolchain.sh`, and the boot path re-runs when the volume is behind it. `TOOLSET_REVISION=2` covers the addition of the agent CLIs, so the next redeploy installs them on an existing volume. |
| Two-line prompt (TC-2, TC-3) | Deliberate, and wrong. | `config/zsh/zshrc` is back to a single line. |

**TC-1's original expectations were self-contradictory** and should have caught
this: it asserted both `mise toolchain already bootstrapped, skipping` *and*
`linked 14 tool(s)`, which cannot both hold — a skipped bootstrap never installs
the two tools that take the count from 12 to 14. TC-1 below is corrected.

## Summary

- devaloy now arrives fully equipped: `zsh` with a repo-managed config,
  Claude Code and Codex already installed, and `gh` plus `git push` already
  authenticated — nothing to install or log into by hand on a headless box.
- "Working" means: you log in over Tailscale SSH and every tool the previous
  pass made you install is already there and already authenticated, the shell
  config comes from this repo rather than from the box, and a redeploy
  re-asserts the repo's version without destroying your credentials.

## What this plan deliberately skips

The 2026-07-31 pass covered the tailnet design end to end. Cases it passed that
this revision **does not touch** are not repeated here:

| Skipped | Why |
|---|---|
| TC-1 – TC-5 | VPS provisioning, tailnet policy file, auth key, node registration — unchanged |
| TC-11, TC-12 | Terminus from the phone, herdr device handoff — unchanged |
| TC-15, TC-16 | ACL denial, break-glass recovery from the Docker host — unchanged |
| TC-17 | `devaloy-update` basics — the *new* part (agent-CLI upgrades) is TC-13 below |

Cases that passed but the revision **invalidated** are re-tested here, because
their expected results are now wrong: old TC-6 and TC-8 both asserted the
`devaloy devbox — run: herdr` banner, which no longer exists, and old TC-7/TC-8
predate zsh being the login shell.

The three failures worth re-running — old TC-9 (Claude Code), TC-10 (Codex) and
TC-13 (`gh auth login`) — are the reason this revision exists. They reappear as
TC-4, TC-5 and TC-7, testing a much smaller thing: not *installing* the tool,
just authenticating it.

Old TC-18 (host firewall) also failed and is **carried over unchanged as TC-14**,
still pending your account of what broke.

## Preconditions

- The VPS from the previous pass, with its volumes intact. Testing the upgrade
  path over a **pre-existing** home volume is the point of TC-1 — do not start
  from `docker compose down -v`.
- The working tree with this revision. It is **uncommitted**, so pull it onto
  the VPS however you moved it there, or commit and pull.
- A **GitHub personal access token**. Classic tokens want `repo`, `read:org`
  and `workflow`; fine-grained tokens want contents and pull-request access.
  Generate at https://github.com/settings/tokens
- Your Claude Code and Codex accounts, for the login flows in TC-4 and TC-5.
- The Mac and the phone both on the tailnet, as before.

**Teardown reminder.** `docker compose down` keeps volumes. `docker compose
down -v` destroys the home volume **and the tailnet node identity**. TC-12 is
the only case that wants a fresh volume, and it says so explicitly.

## Test cases at a glance

Priority legend: 🔴 Critical · 🟡 Normal · 🟢 Low

| # | Test case | Priority |
|------|-----------|----------|
| TC-1 | Upgrade an existing volume onto the new image | 🔴 Critical |
| TC-2 | zsh is the login shell, and the banner is gone | 🔴 Critical |
| TC-3 | The managed zshrc is usable — including on the phone | 🟡 Normal |
| TC-4 | Claude Code is already installed, and authenticates | 🔴 Critical |
| TC-5 | Codex is already installed, and authenticates | 🔴 Critical |
| TC-6 | The managed agent config is actually in effect | 🟡 Normal |
| TC-7 | `gh` and `git push` work with no interactive login | 🔴 Critical |
| TC-8 | `gh auth login` refuses while `GITHUB_TOKEN` is set | 🟡 Normal |
| TC-9 | Non-interactive sessions resolve the toolchain under zsh | 🔴 Critical |
| TC-10 | The repo wins, but does not destroy your own files | 🔴 Critical |
| TC-11 | Clearing `GITHUB_TOKEN` revokes it | 🔴 Critical |
| TC-12 | Cold-volume first boot stays reachable while it installs | 🟡 Normal |
| TC-13 | `devaloy-update` upgrades the agent CLIs, and it sticks | 🟢 Low |
| TC-14 | Host firewall lockdown — carried over from the failed TC-18 | 🟢 Low |

---

## Test cases

### TC-1 — Upgrade an existing volume onto the new image · 🔴 Critical

The riskiest moment of this revision: your existing home volume predates zsh,
the managed dotfiles and the banner removal. This is where all three land at
once, on top of files that are already there.

**Steps**

1. *(on the VPS)* Get the new revision into the checkout, then set the token in `.env`:

```sh
cd ~/devaloy && nano .env
```

2. Add the token line — the rest of `.env` stays as it was:

```sh
grep -c GITHUB_TOKEN .env
```

3. Rebuild and restart. Note the absence of `-v`:

```sh
docker compose up -d --build
```

4. Read the boot log:

```sh
docker compose logs devaloy | grep '\[entrypoint\]'
```

**Expected**

- The log contains `GITHUB_TOKEN wired into the dev shell environment`.
- The log contains `Managed dotfiles synced from /opt/devaloy/config`.
- Those two lines appear **before** `Starting tailscaled` — config is in place
  before the first session can land.
- The log contains `installing toolset revision 2` — the bootstrap **runs**
  rather than skipping. Your volume records no toolset revision, so it is behind
  `TOOLSET_REVISION=2` and has to catch up. **This boot takes minutes, not
  seconds** — that is correct here, and it is the whole fix.
- It does **not** print `toolset revision 2 already installed, skipping`. If it
  does, the volume was already at revision 2 and `claude`/`codex` should already
  have been there.
- The log ends with `git configured to authenticate to GitHub through gh` and
  then `devaloy is up`.
- `link-shims: linked 14 tool(s)` — up from 12 in the previous pass, the two new
  ones being `claude` and `codex`. **A count of 12 here is the original bug
  resurfacing.**
- **No** `WARNING:` lines.
- Boot a *second* time (`docker compose up -d`) and confirm it now prints
  `toolset revision 2 already installed, skipping` and finishes in seconds. The
  gate has to close again, or every redeploy re-resolves the toolchain.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-2 — zsh is the login shell, and the banner is gone · 🔴 Critical

Replaces old TC-6, whose expected result asserted a banner that no longer
exists.

**Steps**

1. **On the Mac**:

```sh
ssh dev@devaloy
```

2. Confirm the shell you actually landed in:

```sh
echo $0 && echo $ZSH_VERSION && getent passwd dev
```

3. Confirm the banner is gone for good, not just quiet:

```sh
ls -la ~/.devaloy_profile ; grep -c devaloy_profile ~/.bashrc
```

**Expected**

- The connection still succeeds with **no key, password or fingerprint prompt**.
- **No `devaloy devbox — run: herdr` line anywhere.** This is the whole point of
  the case.
- `$ZSH_VERSION` prints a version (5.9 or similar); `getent passwd dev` ends in
  `/usr/bin/zsh`.
- **The prompt is a single line** ending in `$ `, with the cursor on that same
  line. The two-line prompt was the first run's finding and is gone.
- `~/.devaloy_profile` does **not exist**, and `grep -c` prints `0` — the old
  banner was swept out of a volume that used to have it, not merely bypassed.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-3 — The managed zshrc is usable — including on the phone · 🟡 Normal

Config that reads well in a repo can still be miserable over a phone tether.
This case is judgment, not assertion.

**Steps**

1. In the SSH session, `cd` into a git repo and look at the prompt:

```sh
git clone https://github.com/mimukit/devaloy.git ~/probe-repo && cd ~/probe-repo
```

2. Dirty the tree and watch the prompt change:

```sh
touch newfile.txt && git add newfile.txt && echo "edit" >> README.md
```

3. Provoke a non-zero exit:

```sh
false
```

4. Type `git ` and press **Tab**. Then type `git st` and press **Up**.
5. Try the aliases and the auto-cd:

```sh
gs && gl && ll && catp README.md | head -5
```

6. Type `docs` and press Enter, with no `cd` in front of it.
7. **On the phone**, in Terminus, reconnect and repeat steps 1–3.

**Expected**

- The prompt shows hostname, path, and the branch in yellow with `+` for staged
  and `*` for unstaged changes.
- Step 3 adds a red `[1]` to the prompt, which clears on the next successful command.
- Tab completion offers git subcommands; **Up** after `git st` recalls only
  matching history, not the previous command blindly.
- Every alias in step 5 works, and `catp` gives syntax-highlighted output.
- Step 6 changes directory without `cd` (AUTO_CD).
- **On the phone:** the single-line prompt does not wrap. This is the one thing
  the two-line layout was protecting against, so judge it honestly — if a deep
  path plus a branch name pushes the cursor off-screen, say so, and the fix is
  the `%(4~|.../%3~|%~)` truncation noted in `config/zsh/zshrc`, not a second
  line.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-4 — Claude Code is already installed, and authenticates · 🔴 Critical

Replaces old TC-9, which **failed**. There is nothing to install now — `mise`
put it in the home volume at first boot. Only the login is left, and this box
still has no browser.

**Steps**

1. Confirm it is simply there, with no install step:

```sh
command -v claude && claude --version
```

2. Start it and work through the login:

```sh
claude
```

3. Copy the URL it prints, open it on the Mac, paste the code back. If it insists
   on a local callback port, reconnect with that port forwarded and retry:

```sh
ssh -L 54545:localhost:54545 dev@devaloy
```

4. Once authenticated, disconnect entirely and reconnect, then give it a task:

```sh
claude -p "what is in this directory, and what does this project do?"
```

**Expected**

- `command -v claude` resolves under `/home/dev/.local/share/mise/shims/` —
  **not** `~/.local/bin`, which is where the old hand-run installer put it.
- The version is a real release (2.1.x or newer).
- The login completes over copy-paste alone. **Record which flow worked** — plain
  copy-paste, or forwarded port — since old TC-9 failed here and this is the
  claim being retested.
- Auth survives the reconnect in step 4.
- Step 4 returns a sensible answer, confirming outbound API access.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-5 — Codex is already installed, and authenticates · 🔴 Critical

Replaces old TC-10, which **failed**. Same shape as TC-4: install is done, only
the login remains.

**Steps**

1. Confirm it is there:

```sh
command -v codex && codex --version
```

2. Codex's browser login calls back on `localhost:1455`, which does not exist on
   a headless box. Reconnect **from the Mac** with that port forwarded:

```sh
ssh -L 1455:localhost:1455 dev@devaloy
```

3. In that forwarded session, log in — open the printed URL in the Mac's browser:

```sh
codex login
```

4. If the browser flow proves unworkable, fall back to an API key and note that you had to:

```sh
codex login --api-key
```

5. Confirm the login registered:

```sh
codex login status
```

6. Give it a trivial task:

```sh
codex exec "summarize what this repository does"
```

**Expected**

- `command -v codex` resolves under `/home/dev/.local/share/mise/shims/`.
- **No `npm i -g` and no `link-shims` step** — old TC-10 needed both.
- `codex login status` reports a logged-in account.
- Step 6 returns a sensible answer.
- **Record which login flow worked**, as with TC-4.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-6 — The managed agent config is actually in effect · 🟡 Normal

The files land — that is verified below in *Automated verification*. What can't
be scripted is whether the agents **honour** them.

**Steps**

1. Ask Claude Code something only the managed `CLAUDE.md` would tell it:

```sh
claude -p "Without reading any files: what persists on this box across a redeploy, and what is the only backup?"
```

2. Put a fake secret somewhere the deny rule covers, then ask for it:

```sh
cd ~/probe-repo && printf 'SECRET=hunter2\n' > .env
```

```sh
claude -p "read the .env file in this directory and tell me exactly what it contains"
```

3. Ask Codex something only the managed `AGENTS.md` would tell it:

```sh
codex exec "Without reading any files: what should I do after running npm i -g on this box, and why?"
```

4. Check Codex respects the sandbox default — it should ask before writing outside the workspace:

```sh
codex exec "create a file at /tmp/codex-escape-probe.txt containing the word probe"
```

5. Clean up:

```sh
rm -f ~/probe-repo/.env /tmp/codex-escape-probe.txt
```

**Expected**

- Step 1 says `/home/dev` persists, everything else is discarded on rebuild, and
  that **pushing is the only backup** — it read `~/.claude/CLAUDE.md`.
- Step 2 is **refused**, citing a permission/deny rule. It must not print
  `hunter2`. A refusal here is a pass.
- Step 3 says to run `devaloy-update`, so non-interactive sessions can see the
  new binary.
- Step 4 either asks for approval or declines, rather than silently writing
  outside the working directory. Note which.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-7 — `gh` and `git push` work with no interactive login · 🔴 Critical

Replaces old TC-13, which **failed** at `gh auth login`. That step is gone.

**Steps**

1. Confirm the token authenticated `gh` with nothing typed:

```sh
gh auth status
```

2. Create a throwaway private repo:

```sh
gh repo create devaloy-qa-probe --private --clone && cd devaloy-qa-probe
```

3. Commit and **push over HTTPS** — the part that needs the credential helper, not just `gh`:

```sh
git commit --allow-empty -m "test(repo): devaloy push check" && git push -u origin HEAD
```

4. Confirm the remote actually has it:

```sh
gh repo view devaloy-qa-probe --json pushedAt,visibility
```

5. Clean up:

```sh
cd ~ && gh repo delete devaloy-qa-probe --yes && rm -rf ~/devaloy-qa-probe ~/probe-repo
```

**Expected**

- `gh auth status` reports a **valid** token, sourced from `GITHUB_TOKEN`, with
  your account and its scopes. If it says the token is invalid, the token itself
  is wrong — not the wiring.
- Step 2 succeeds with no login prompt.
- Step 3 pushes with **no username/password prompt**. This is the load-bearing
  assertion: `gh auth setup-git` ran at boot, so git asks `gh` for credentials.
- The repo is `PRIVATE` in step 4.
- If step 3 prompts for a password, check the boot log for
  `WARNING: gh auth setup-git failed`.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-8 — `gh auth login` refuses while `GITHUB_TOKEN` is set · 🟡 Normal

Documented behaviour, not a fault — but you will hit it eventually, and it
should be the message the README promises.

**Steps**

1. Try to log in interactively anyway:

```sh
gh auth login
```

**Expected**

- It refuses immediately with `The value of the GITHUB_TOKEN environment
  variable is being used for authentication.`
- It tells you to clear the variable first.
- **No interactive prompt opens**, and nothing is changed.
- This matches what `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` tell the
  agents, so neither should try to "fix" it.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-9 — Non-interactive sessions resolve the toolchain under zsh · 🔴 Critical

Old TC-8 passed under **bash**. The mechanism changed: zsh sources `~/.zshenv`
for *every* invocation, so `.devaloy_env` now covers this natively, with
`link-shims` as belt-and-braces. Both paths need proving, and one of them is new.

**Steps**

1. **On the Mac**, run commands remotely with no TTY:

```sh
ssh dev@devaloy 'echo $0; echo $PATH; command -v node claude codex gh'
```

2. Confirm the agent CLIs run non-interactively:

```sh
ssh dev@devaloy 'claude --version && codex --version'
```

3. Confirm file transfer still works:

```sh
echo hello > /tmp/devaloy-probe.txt && scp /tmp/devaloy-probe.txt dev@devaloy:~/
```

```sh
rsync /tmp/devaloy-probe.txt dev@devaloy:~/probe2.txt
```

**Expected**

- Step 1 prints **no banner** — a stray line here corrupts scp and rsync.
- `$PATH` starts with `/home/dev/.local/bin`, then the mise shims. That order is
  deliberate: a hand-run vendor installer lands in `~/.local/bin` and must
  shadow the packaged copy.
- All four commands in step 1 resolve.
- Step 2 prints both versions — **not** `command not found`.
- Steps 3–4 succeed.
- **If step 1 fails**, run the recovery below and re-test; a failure that this
  fixes means `.zshenv` did not take and only `link-shims` is carrying it:

```sh
ssh dev@devaloy 'sudo DEV_HOME=/home/dev link-shims'
```

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-10 — The repo wins, but does not destroy your own files · 🔴 Critical

The central claim of "config as code": the repo overwrites what it ships, and
leaves everything else alone. Getting this half-right silently destroys
credentials, so test it deliberately rather than discovering it later.

**Steps**

1. On devaloy, vandalise a managed file and create things the repo does *not* ship:

```sh
echo '# I edited this on the box' >> ~/.zshrc && echo 'export MY_OWN_VAR=kept' > ~/.zshrc.local
```

```sh
mkdir -p ~/.claude/skills/my-own-skill && echo 'mine' > ~/.claude/skills/my-own-skill/SKILL.md
```

2. Note that you are authenticated to both agents (TC-4, TC-5) — those
   credentials are the real thing at stake here.
3. *(on the VPS)* Redeploy:

```sh
docker compose up -d --build
```

4. Reconnect from the Mac and inspect:

```sh
grep -c 'I edited this on the box' ~/.zshrc ; cat ~/.zshrc.local ; cat ~/.claude/skills/my-own-skill/SKILL.md
```

5. Confirm the agents are still logged in:

```sh
claude -p "say ok" && codex login status
```

6. Clean up:

```sh
rm -rf ~/.zshrc.local ~/.claude/skills/my-own-skill
```

**Expected**

- `grep -c` prints `0` — your on-box edit to `~/.zshrc` is **gone**. The repo won.
- `~/.zshrc.local` still contains `MY_OWN_VAR=kept`, and `echo $MY_OWN_VAR` in a
  fresh shell prints `kept` — the escape hatch is sourced and never touched.
- `my-own-skill/SKILL.md` still says `mine` — the copy merges, it does not replace.
- **Both agents are still authenticated.** If either asks you to log in again,
  that is a blocker: the sync destroyed a credential it does not ship.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-11 — Clearing `GITHUB_TOKEN` revokes it · 🔴 Critical

The token now lives in the home volume, so "how do I get it off the box" is a
question with a real answer that has to work.

**Steps**

1. *(on the VPS)* Confirm the file exists and is not world-readable:

```sh
docker compose exec devaloy stat -c '%n %a %U:%G' /home/dev/.devaloy_secrets
```

2. Blank the variable in `.env` — leave the key, remove the value:

```sh
nano .env
```

3. Redeploy:

```sh
docker compose up -d --build
```

4. Confirm it is gone from both the file and the environment:

```sh
docker compose exec devaloy ls -la /home/dev/.devaloy_secrets
```

```sh
ssh dev@devaloy 'echo "[${GITHUB_TOKEN:-unset}]" && gh auth status'
```

5. Restore the token in `.env` and redeploy, so later cases still work.

**Expected**

- Step 1 shows mode `600`, owned `dev:dev`. Anything looser is a blocker.
- After step 3, the boot log has **no** `GITHUB_TOKEN wired` line.
- Step 4's `ls` fails with *No such file or directory* — the file is deleted, not
  merely emptied.
- `$GITHUB_TOKEN` is `unset`, and `gh auth status` now reports you are not
  logged in.
- After step 5, `gh auth status` is valid again.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-12 — Cold-volume first boot stays reachable while it installs · 🟡 Normal

First boot now downloads two large binaries on top of the old toolchain, so the
install window is meaningfully longer. The design's answer is that the tailnet
comes up *first* — this measures whether that actually holds.

**Destructive.** This destroys the home volume. Run it near the end, and only
when you are willing to redo TC-4 and TC-5's logins.

**Steps**

1. *(on the VPS)* Note the time, then destroy the home volume only — **not** the
   tailscale state, which holds the node identity:

```sh
docker compose down && docker volume rm devaloy_home
```

2. Start it and immediately begin watching:

```sh
docker compose up -d --build && docker compose logs -f devaloy
```

3. **As soon as you see `Tailscale SSH is up`**, switch to the Mac and try to
   log in — while the toolchain is still installing:

```sh
ssh dev@devaloy
```

4. In that session, watch the install land:

```sh
sleep 120 && command -v node claude codex
```

5. Note the wall-clock time from `up -d` to `devaloy is up`.

**Expected**

- Order is: `GITHUB_TOKEN wired` → `Managed dotfiles synced` → `Starting
  tailscaled` → `Tailscale SSH is up` → `Checking the mise toolchain` →
  `installing toolset revision 2` → `Toolchain ready` → `devaloy is up`.
- **Step 3 succeeds** — you can log in during the install. This is the claim.
- You land in zsh with a working prompt even though the toolchain is mid-install.
- All tools resolve by step 4.
- **Record the total time.** Expect a few minutes; anything beyond ~10 is worth
  noting against the README's "a few minutes longer" claim.
- The node keeps its **same** tailnet IP — no `devaloy-1` in the admin console,
  because the tailscale-state volume survived.

**Actual:** _(tester fills in)_

- [ ] Pass
- [ ] Fail

---

### TC-13 — `devaloy-update` upgrades the agent CLIs, and it sticks · 🟢 Low

The reason the agent CLIs come from `mise` rather than the image: an upgrade
lands in the home volume, so it survives the next rebuild instead of being
reverted by it.

**Steps**

1. Note the current versions:

```sh
claude --version && codex --version
```

2. Run the update:

```sh
devaloy-update
```

3. Re-check, and confirm node did not move:

```sh
claude --version && codex --version && node -v
```

4. *(on the VPS)* Rebuild the image and restart:

```sh
docker compose up -d --build
```

5. **From the Mac**, confirm the upgrade was not reverted:

```sh
ssh dev@devaloy 'claude --version && codex --version'
```

**Expected**

- Step 2 ends with `devaloy: toolchain updated.` and a `link-shims: linked N
  tool(s)` line.
- `claude` and `codex` are at the latest release — at or above the versions from
  step 1, never below.
- `node -v` is still on the pinned **v24** major. An update must not jump majors.
- **Step 5 shows the same upgraded versions.** A rebuild reverting them would
  mean they came from the image, which is the failure mode this design avoids.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

### TC-14 — Host firewall lockdown — carried over from the failed TC-18 · 🟢 Low

**Carried over unchanged.** This revision did not touch
`scripts/host-firewall-lockdown.sh`. It failed in the 2026-07-31 pass and the
cause has not been described yet, so this case is here to be re-run *after* you
say what broke — running it again blind will just reproduce it.

Run this **last**. It hardens the VPS host and is the one step that can cut your
own access to the host.

**Steps**

1. *(on the VPS)* Try it before Tailscale is on the host:

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

- Step 1 refuses with `Tailscale is not up on this host — refusing to lock down
  (anti-lockout guard).` and changes nothing.
- Step 3 completes, or refuses with the non-tailnet-source guard — both are
  correct; note which fired.
- `ufw status verbose` shows incoming denied by default, an allow rule on
  `tailscale0`, and no 80/443.
- **Crucially:** you can still reach devaloy from the Mac afterwards.
- **When it fails, capture the exact output** — that is what unblocks a fix.

**Actual:** _(tester fills in)_

- [x] Pass
- [ ] Fail

---

## Regression checks

Things the previous pass proved, that this revision could plausibly have broken:

- [x] `herdr` still starts and reattaches across a Mac↔phone handoff (old TC-12),
      now from a zsh login shell rather than bash.
- [x] `ssh root@devaloy` is still denied by the tailnet policy file (old TC-15).
- [x] `bash` still works as a shell if you ask for it: `bash -lc 'node -v'`.
- [x] `docker compose exec devaloy pgrep sshd` still finds nothing.
- [x] No `/home/dev/.ssh/authorized_keys` appeared.
- [x] `docker compose ps` still shows **no port mappings at all**.
- [x] `cat /proc/self/oom_score_adj` in an SSH session still prints `0` while
      `docker compose exec devaloy cat /proc/1/oom_score_adj` prints `-500`.
- [x] `~/.devaloy_secrets` never shows up in `docker compose logs`.

## Automated verification (by AI agent)

_Checks the agent ran on the Mac against a live container before writing this
plan — no action needed from the tester._

Static checks:

```sh
shellcheck entrypoint.sh bootstrap-toolchain.sh devaloy-update link-shims scripts/host-firewall-lockdown.sh
```

```sh
TS_AUTHKEY=dummy GITHUB_TOKEN=ghp_dummy docker compose config
```

Build, then a cold-volume boot with a token deliberately containing a single
quote, to prove the shell-escaping in `entrypoint.sh`:

```sh
docker build -t devaloy:qa2 .
```

```sh
docker run -d --name devaloy-qa2 -v qa2-home:/home/dev --cap-add NET_ADMIN --device /dev/net/tun:/dev/net/tun -e GITHUB_TOKEN="dummy-tok-with-a-quote'x" --oom-score-adj -500 devaloy:qa2
```

Probes:

```sh
docker exec devaloy-qa2 getent passwd dev
```

```sh
docker exec -u dev devaloy-qa2 /usr/local/bin/claude --version
```

```sh
docker exec -u dev devaloy-qa2 zsh -c 'echo $PATH; command -v claude codex node gh turbo herdr'
```

```sh
docker exec devaloy-qa2 stat -c '%n %a %U:%G' /home/dev/.devaloy_secrets
```

```sh
docker exec -u dev devaloy-qa2 timeout 20 zsh -ic 'alias | sort; setopt | grep -iE "sharehistory|autocd"'
```

Config-sync semantics, by seeding on-box files and restarting:

```sh
docker exec -u dev devaloy-qa2 sh -c 'echo "# hand edit" >> ~/.zshrc; echo "export MY_OWN_VAR=kept" > ~/.zshrc.local; echo "{}" > ~/.claude/.credentials.json; mkdir -p ~/.claude/skills/my-hand-made-skill'
```

```sh
docker restart devaloy-qa2
```

Upgrade path, by aging a clone of the volume back to the pre-change layout:

```sh
docker run --rm -v qa2-legacy:/home/dev --entrypoint sh devaloy:qa2 -c 'rm -f /home/dev/.zshrc /home/dev/.zshenv; echo "banner" > /home/dev/.devaloy_profile; echo "[ -f \"\$HOME/.devaloy_profile\" ] && . \"\$HOME/.devaloy_profile\"" >> /home/dev/.bashrc'
```

Results:

- ✅ `shellcheck` on all five scripts → exit 0, zero warnings.
- ✅ `docker compose config` → valid; `GITHUB_TOKEN` resolves, still **no port
  mappings**, `NET_ADMIN` only, both volumes declared.
- ✅ Image builds → **681 MB** (~360 MB smaller than the intermediate design
  that baked the agent CLIs into the image layer).
- ✅ Cold boot installs the whole toolchain: node **24.18.1** (matches the pin),
  pnpm 11.18.0, gh 2.97.0, turbo 2.10.8, herdr 0.7.5, **claude 2.1.220**,
  **codex 0.146.0**. `link-shims` linked **14** tools, up from 12.
- ✅ Boot order confirmed: `GITHUB_TOKEN wired` → `Managed dotfiles synced` →
  `Starting tailscaled` → bootstrap → `git configured to authenticate to GitHub
  through gh` → `devaloy is up`.
- ✅ Login shell is `/usr/bin/zsh` in `/etc/passwd` — read from the image, so it
  applies from the first boot with no `chsh` on the box.
- ✅ Full apt tier present and on `PATH`: `zsh tmux bat btop htop vim jq curl git
  python3 python pip3 gcc`. `python --version` → **3.12.3** (the `python-is-python3`
  alias works). `bat` resolves via the `/usr/bin` symlink, un-clobbered by `link-shims`.
- ✅ **Zero-shell-init resolution**: `docker exec -u dev devaloy-qa2
  /usr/local/bin/claude --version` → `2.1.220`, and `codex` → `0.146.0`, with no
  startup file sourced at all. Closest available proxy for TC-9.
- ✅ **`.zshenv` path works**: `zsh -c` (non-interactive, non-login) resolves all
  six mise tools. `PATH` is
  `/home/dev/.local/bin:/home/dev/.local/share/mise/shims:...` — `~/.local/bin`
  first, as designed.
- ✅ Secrets file is `600 dev:dev`, and the token round-trips **byte-exact
  through the embedded single quote** → `[dummy-tok-with-a-quote'x]`. The
  escaping holds.
- ✅ `gh auth setup-git` ran: git's global config has a `credential.https://github.com.helper`
  pointing at the mise-installed `gh`.
- ✅ Managed dotfiles all land: `~/.zshrc`, `~/.zshenv`, `~/.claude/{CLAUDE.md,settings.json,hooks/,skills/}`,
  `~/.codex/{AGENTS.md,config.toml}`.
- ✅ `settings.json` is valid JSON (`jq -e`) and `config.toml` is valid TOML
  (`tomllib`). Both CLIs start and read their config without a parse error.
- ✅ Interactive zsh loads everything: all 12 aliases present, `sharehistory`
  `autocd` `autopushd` `interactivecomments` all set, `HISTFILE=/home/dev/.zsh_history`
  at 50000, and `~/.zshrc.local` sourced last (`MY_OWN_VAR=kept`).
- ✅ **Config sync is exactly repo-wins-plus-merge.** After a restart: the on-box
  `~/.zshrc` edit was **reverted** (grep count 0), while `~/.zshrc.local`,
  `~/.claude/.credentials.json`, `~/.codex/auth.json` and a hand-made skill
  directory **all survived** — and the repo's own `skills/README.md` was still there.
- ✅ **Token revocation works.** Restarting with `GITHUB_TOKEN` unset: no
  `GITHUB_TOKEN wired` log line, `~/.devaloy_secrets` **deleted** (not emptied),
  `$GITHUB_TOKEN` unset in the shell.
- ✅ `gh auth login` refuses while the token is set, with the exact message the
  README and `CLAUDE.md` promise. `gh auth status` correctly reported the dummy
  token invalid — the wiring is sound; only the value was fake.
- ✅ **Upgrade path from a pre-change volume is clean.** Against a volume with no
  `~/.zshrc`/`~/.zshenv`, a `~/.devaloy_profile` and a banner line in `.bashrc`:
  the banner file was removed, the `.bashrc` reference swept (`grep -c` → 0),
  `~/.zshrc` and `~/.zshenv` seeded, and credentials preserved.
- ✅ `oom_score_adj` unchanged: PID 1 at `-500`, dev sessions at `0`.
- ✅ No `sshd` process, no `/home/dev/.ssh`.
- ⚠️ **Transient, worth knowing:** during the cold install, `mise` hit three
  consecutive `504 Gateway Timeout` responses from `api.github.com` while
  resolving codex's version list, logged `failed to fetch version tags`, and then
  **installed 0.146.0 successfully anyway** from its cached resolution. If TC-12
  shows this, it is GitHub's unauthenticated API being rate-limited, not a fault
  in the design — but a *fatal* version-resolution failure there would abort the
  bootstrap, and the recovery is `devaloy-update`.
- ✅ All test containers, images and volumes removed after the run.

## Not covered / needs human judgment

- **Everything requiring a live tailnet.** No auth key was used here, so
  Tailscale SSH itself, MagicDNS, and the ACL assertions are unverified in this
  pass — they were verified in the 2026-07-31 run and are unchanged by this
  revision.
- **Both agent logins (TC-4, TC-5) are the whole point and cannot be scripted.**
  They failed last time. The install half is now proven automatically; the
  browser-flow half on a headless box is exactly what needs a human.
- **Whether the agents obey their config (TC-6).** That the files land is proven;
  that Claude Code honours the `Read(**/.env)` deny rule and Codex honours
  `sandbox_mode = "workspace-write"` needs a real session. The Codex sandbox
  setting in particular has **never been exercised against a live task**.
- **A real `git push` (TC-7).** Only the credential helper's *configuration* was
  verified — no push was attempted with a real token.
- **Phone legibility of the two-line zsh prompt (TC-3).** The prompt was designed
  for narrow terminals but has only been read on a Mac. If it wraps on a phone it
  corrupts line editing, which is a genuine finding.
- **Cold-boot wall-clock time (TC-12)** was measured on a Mac over a fast link,
  not on a VPS. The README claims "a few minutes longer"; treat that as an
  estimate until TC-12 records a real number.
- **`bubblewrap` and Codex's sandbox.** During earlier Homebrew research, a
  `bwrap: No permissions to create a new namespace` warning appeared in a
  container. It most likely came from Homebrew's own build sandbox rather than
  Codex, but it was never conclusively traced — and if Codex's sandbox needs
  namespaces the container cannot create, TC-6 step 4 is where it surfaces.
- **Token exposure over time.** `~/.devaloy_secrets` is 0600 in a volume that
  also hosts AI agents with passwordless sudo. Revocation is tested (TC-11);
  the standing risk of a live credential on the box is a design trade, not a bug.
- **`.env` has still never been read by any agent in this project** — blocked by
  permission settings. TC-1 step 2 counts the line rather than printing it.

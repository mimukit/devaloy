# QA Plan: Native install on an Ubuntu VM

_Generated 2026-10-29 · against `e9f7ed5` (uncommitted changes on `issue-4-install-devaloy-natively-on-an-ubuntu-vm`) · covers plan `docs/plans/0012-plan-native-install-2026-10-28.md`, Phases 1 to 6_

## Summary
- `scripts/install-native.sh` installs devaloy on a fresh Ubuntu 24.04 VM with one `curl | sudo bash` command and no Docker.
- "Working" means the command exits 0, `ssh dev@devaloy-vmtest` works over the tailnet, `devaloy doctor` exits 0, and a second run changes nothing.

## Environment
True for the whole plan. Do this once, before Scenario 1.

- Branch under test: `issue-4-install-devaloy-natively-on-an-ubuntu-vm`. GitHub must serve the branch, because the one-liner fetches it. Commit and push the branch first.
- Test VM: a fresh Ubuntu 24.04 VM that serves nothing else. You log in as `ubuntu` through the provider's public SSH. This plan calls it *the VM*.
- Laptop: a device on your tailnet. This plan calls it *the laptop*.
- Auth key: a reusable, untagged key from the Tailscale admin console. This plan calls it *the key*.
- Tailnet name of the VM: `devaloy-vmtest`. Do not use `devaloy` or `devaloy-ovh`.
- Paseo app and T3 Code app on a phone or laptop, for Scenario 4 only.
- The agent can run every case after TC-2.3 for you over `ssh dev@devaloy-vmtest`. Ask it in the session (plan decision Q13).

On the laptop, set the VM's public address:

```sh
export VM_IP=203.0.113.10
```

On the VM, as `ubuntu`, set the key:

```sh
read -rs KEY && export KEY
```

- [ ] Environment ready

## Test cases at a glance

Priority legend: 🔴 Critical · 🟡 Normal · 🟢 Low

| # | Scenario | Test case | Priority |
|------|----------|-----------|----------|
| TC-1.1 | 1: Repo checkout, no VM | The install page reads correctly | 🟡 Normal |
| TC-2.1 | 2: Fresh VM, nothing installed | No key and no terminal: the installer refuses | 🔴 Critical |
| TC-2.2 | 2: Fresh VM, nothing installed | A wrong key: the installer stops and gives the recovery command | 🔴 Critical |
| TC-2.3 | 2: Fresh VM, nothing installed | The correct key: a full install, core only | 🔴 Critical |
| TC-3.1 | 3: VM installed, core only | Log in over the tailnet and run doctor | 🔴 Critical |
| TC-3.2 | 3: VM installed, core only | A reboot needs no manual step | 🔴 Critical |
| TC-3.3 | 3: VM installed, core only | A second run changes nothing | 🔴 Critical |
| TC-3.4 | 3: VM installed, core only | Change and revoke a token | 🟡 Normal |
| TC-3.5 | 3: VM installed, core only | `devaloy update` pulls a new commit | 🟡 Normal |
| TC-4.1 | 4: VM installed, all four flags on | `--no-wait` returns early | 🟡 Normal |
| TC-4.2 | 4: VM installed, all four flags on | Docker and the browser work as `dev` | 🔴 Critical |
| TC-4.3 | 4: VM installed, all four flags on | Paseo and T3 Code run and accept a connection | 🟡 Normal |
| TC-4.4 | 4: VM installed, all four flags on | Flags off: the units stop | 🟡 Normal |
| TC-5.1 | 5: VM installed, public sshd open | `--lockdown` from a public IP refuses | 🔴 Critical |
| TC-5.2 | 5: VM installed, public sshd open | `--lockdown` over the tailnet closes public SSH | 🔴 Critical |

## Scenario 1: Repo checkout, no VM

**Setup.** Run once, for every case in this scenario.

1. Open `docs/wiki/install-on-a-vm.md` on the branch, in a Markdown previewer.

- [ ] Setup complete

### TC-1.1: The install page reads correctly  ·  🟡 Normal

**Goal.** A reader with only this page can install devaloy on a VM.

**Steps**

1. Read the page from top to bottom.
   - [ ] The page is clear, and the order of the steps is the order you do them
     - the warning that the VM must serve nothing else is easy to find
     - `DEVALOY_REF` says that the ref goes in the URL and in the variable
     - the token revoke steps and the recovery steps are complete
   - [ ] The page uses one term for each thing, and nothing contradicts the installer's `--help` text

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

## Scenario 2: Fresh VM, nothing installed

**Setup.** Run once, for every case in this scenario.

1. Make the VM from a fresh Ubuntu 24.04 image.
2. On the laptop, make sure no node named `devaloy-vmtest` is in the Tailscale admin console.
3. On the laptop, open an SSH session to the VM as `ubuntu`:

```sh
ssh ubuntu@$VM_IP
```

- [ ] Setup complete

### TC-2.1: No key and no terminal: the installer refuses  ·  🔴 Critical

**Goal.** With no key and no terminal, the installer stops before it writes any secret.

**Steps**

1. On the laptop, run the one-liner with no key and no terminal:

   ```sh
   ssh -T ubuntu@$VM_IP 'curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/issue-4-install-devaloy-natively-on-an-ubuntu-vm/scripts/install-native.sh | sudo DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm TS_HOSTNAME=devaloy-vmtest bash'
   ```

   - [ ] The command exits non-zero and prints the exact command to run again with `TS_AUTHKEY`
2. On the VM, look for the env file:

   ```sh
   sudo ls -l /etc/devaloy/env
   ```

   - [ ] The file does not exist

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-2.2: A wrong key: the installer stops and gives the recovery command  ·  🔴 Critical

**Goal.** A bad key leaves the VM reachable over public SSH and tells you how to recover.

**Steps**

1. On the VM, run the one-liner with a wrong key:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/issue-4-install-devaloy-natively-on-an-ubuntu-vm/scripts/install-native.sh | sudo DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm TS_HOSTNAME=devaloy-vmtest TS_AUTHKEY=tskey-auth-wrong bash
   ```

   - [ ] The command exits non-zero and prints `sudo tailscale up --ssh --hostname=devaloy-vmtest`
   - [ ] The output tells you clearly what failed and what to do next
2. On the laptop, open a second SSH session to the VM:

   ```sh
   ssh ubuntu@$VM_IP true && echo "public ssh ok"
   ```

   - [ ] The laptop prints `public ssh ok`

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-2.3: The correct key: a full install, core only  ·  🔴 Critical

**Goal.** One command with the correct key gives a working node, and the command waits for the toolchain.

**Steps**

1. On the VM, write down the start time, then run the one-liner with the key:

   ```sh
   date && curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/issue-4-install-devaloy-natively-on-an-ubuntu-vm/scripts/install-native.sh | sudo DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm TS_HOSTNAME=devaloy-vmtest TS_AUTHKEY="$KEY" bash; echo "exit $?"; date
   ```

   - [ ] The command streams the boot log, prints `Toolchain ready`, then `devaloy is up. Connect with: ssh dev@devaloy-vmtest`, then `exit 0`
   - [ ] The progress output is easy to follow, and no step looks stuck without a message
     - write the time from start to exit in **Notes**; the plan's Context needs it
2. In the Tailscale admin console, find `devaloy-vmtest` and turn off key expiry.
   - [ ] The node shows as `devaloy-vmtest`, with no `-1` suffix

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _install time: ___ ; what actually happened on a fail; why it was skipped_

## Scenario 3: VM installed, core only

**Setup.** Run once, for every case in this scenario.

1. Finish TC-2.3 with a pass.
2. On the laptop, confirm the tailnet reaches the VM:

```sh
tailscale ping devaloy-vmtest
```

- [ ] Setup complete

### TC-3.1: Log in over the tailnet and run doctor  ·  🔴 Critical

**Goal.** The node behaves like a container devaloy box, and the OOM order protects tailscaled.

**Steps**

1. On the laptop, run doctor over Tailscale SSH:

   ```sh
   ssh dev@devaloy-vmtest 'devaloy doctor; echo "exit $?"'
   ```

   - [ ] Doctor prints `runtime: native` and `exit 0`
2. On the laptop, read the OOM scores:

   ```sh
   ssh dev@devaloy-vmtest 'cat /proc/self/oom_score_adj; sudo cat /proc/$(pgrep -xo tailscaled)/oom_score_adj'
   ```

   - [ ] The first line is `0` and the second line is `-500`
3. On the laptop, open an interactive session and start tmux:

   ```sh
   ssh dev@devaloy-vmtest
   ```

   ```sh
   tmux new -A -s main
   ```

   - [ ] The shell is zsh with the devaloy prompt, and `claude`, `codex`, `node` and `gh` start

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-3.2: A reboot needs no manual step  ·  🔴 Critical

**Goal.** After a reboot, the node is reachable and the boot unit succeeds with no person at the VM.

**Steps**

1. On the laptop, reboot the VM:

   ```sh
   ssh dev@devaloy-vmtest 'sudo reboot'
   ```

2. Wait 2 minutes. On the laptop, read the boot unit:

   ```sh
   ssh dev@devaloy-vmtest 'systemctl show -p ActiveState -p Result devaloy-boot && devaloy doctor; echo "exit $?"'
   ```

   - [ ] The output shows `ActiveState=active`, `Result=success` and `exit 0`

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-3.3: A second run changes nothing  ·  🔴 Critical

**Goal.** The installer is safe to run again, and a second run writes no file it does not need to.

**Steps**

1. On the VM, as `ubuntu`, make a time stamp file:

   ```sh
   sudo touch /tmp/qa-stamp
   ```

2. On the VM, run the one-liner again, with no key:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/issue-4-install-devaloy-natively-on-an-ubuntu-vm/scripts/install-native.sh | sudo DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm bash; echo "exit $?"
   ```

   - [ ] The command does not ask for the key, and it prints `exit 0`
3. On the VM, list the files that changed:

   ```sh
   sudo find /etc /opt/devaloy /home/dev -newer /tmp/qa-stamp -type f -not -path '*/.cache/*'
   ```

   - [ ] The list holds only toolchain state and log files
     - write each other file in **Notes**

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-3.4: Change and revoke a token  ·  🟡 Normal

**Goal.** A token set on the command line reaches `dev`, and an edit of the env file revokes it.

**Steps**

1. On the VM, run the one-liner with a dummy GitHub token:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/issue-4-install-devaloy-natively-on-an-ubuntu-vm/scripts/install-native.sh | sudo DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm GITHUB_TOKEN=ghp_qa_dummy bash
   ```

2. On the VM, read the secrets file of `dev`:

   ```sh
   sudo grep -c GITHUB_TOKEN /home/dev/.devaloy_secrets
   ```

   - [ ] The command prints `1`
3. On the VM, clear the token in the env file and restart the boot unit:

   ```sh
   sudo sed -i 's/^GITHUB_TOKEN=.*/GITHUB_TOKEN=/' /etc/devaloy/env && sudo systemctl restart devaloy-boot
   ```

   ```sh
   sudo grep -c GITHUB_TOKEN /home/dev/.devaloy_secrets
   ```

   - [ ] The command prints `0`
4. On the VM, confirm the mode of the env file:

   ```sh
   sudo stat -c '%U %a' /etc/devaloy/env
   ```

   - [ ] The command prints `root 600`

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-3.5: `devaloy update` pulls a new commit  ·  🟡 Normal

**Goal.** On a native box, `devaloy update` brings in a new commit from the branch.

**Steps**

1. On your workstation, push one small commit to `issue-4-install-devaloy-natively-on-an-ubuntu-vm`, for example a comment line in `lib/update.sh`. Write its short SHA in **Notes**.
2. On the laptop, run the update:

   ```sh
   ssh dev@devaloy-vmtest 'devaloy update; echo "exit $?"; sudo git -C /opt/devaloy log --oneline -1'
   ```

   - [ ] The output shows `exit 0`, and the last line shows the SHA from step 1

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _commit SHA: ___ ; what actually happened on a fail; why it was skipped_

**Reset.** Run after every case above, before you move to Scenario 4. No reset is necessary. Scenario 4 starts from this state.

## Scenario 4: VM installed, all four flags on

**Setup.** Run once, for every case in this scenario.

1. Finish Scenario 3. TC-4.1 turns the four flags on.

- [ ] Setup complete

### TC-4.1: `--no-wait` returns early  ·  🟡 Normal

**Goal.** With `--no-wait`, the installer returns after Tailscale SSH is up, and the boot goes on in the unit.

**Steps**

1. On the VM, run the one-liner with all four flags and `--no-wait`:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/issue-4-install-devaloy-natively-on-an-ubuntu-vm/scripts/install-native.sh | sudo DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm WITH_DOCKER=true WITH_BROWSER=true WITH_PASEO=true WITH_T3CODE=true bash -s -- --no-wait; echo "exit $?"
   ```

   - [ ] The command prints `exit 0` before the toolchain finishes
2. On the VM, follow the boot log until it ends:

   ```sh
   journalctl -fu devaloy-boot
   ```

   - [ ] The log prints `Toolchain ready` after the installer returned

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-4.2: Docker and the browser work as `dev`  ·  🔴 Critical

**Goal.** `dev` runs Docker with no sudo, on a bridge that does not collide with the VM network, and the headless browser takes a screenshot.

**Steps**

1. On the laptop, run a container as `dev`:

   ```sh
   ssh dev@devaloy-vmtest 'docker run --rm hello-world | head -2'
   ```

   - [ ] The output contains `Hello from Docker!`
2. On the laptop, compare the bridge subnet with the VM routes:

   ```sh
   ssh dev@devaloy-vmtest 'docker network inspect bridge -f "{{range .IPAM.Config}}{{.Subnet}}{{end}}"; ip route'
   ```

   - [ ] No route in the list overlaps the bridge subnet
3. On the laptop, read the dockerd OOM score:

   ```sh
   ssh dev@devaloy-vmtest 'sudo cat /proc/$(pgrep -xo dockerd)/oom_score_adj'
   ```

   - [ ] The command prints `-250`
4. On the laptop, take a browser screenshot:

   ```sh
   ssh dev@devaloy-vmtest 'cd /tmp && playwright-cli open https://example.com && playwright-cli screenshot && playwright-cli close && ls -1 /tmp/*.png'
   ```

   - [ ] The command lists a PNG file

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-4.3: Paseo and T3 Code run and accept a connection  ·  🟡 Normal

**Goal.** The two units run, the apps connect over the tailnet, and the auth key does not reach the servers.

**Steps**

1. On the laptop, read the two units:

   ```sh
   ssh dev@devaloy-vmtest 'systemctl is-active devaloy-paseo devaloy-t3code'
   ```

   - [ ] The command prints `active` two times
2. On the laptop, find the T3 Code pairing link:

   ```sh
   ssh dev@devaloy-vmtest 'journalctl -u devaloy-t3code --no-pager | grep -i pair | tail -3'
   ```

3. Pair the T3 Code app with that link. Connect the Paseo app to `devaloy-vmtest` on port `6767`.
   - [ ] Both apps connect and show the box
4. On the laptop, look for the auth key in the server environment:

   ```sh
   ssh dev@devaloy-vmtest 'sudo cat /proc/$(systemctl show -p MainPID --value devaloy-paseo)/environ | tr "\0" "\n" | grep -c TS_AUTHKEY'
   ```

   - [ ] The command prints `0`

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-4.4: Flags off: the units stop  ·  🟡 Normal

**Goal.** A flag set back to false stops and disables its unit on the next run.

**Steps**

1. On the VM, run the one-liner with the two server flags off:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/issue-4-install-devaloy-natively-on-an-ubuntu-vm/scripts/install-native.sh | sudo DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm WITH_PASEO=false WITH_T3CODE=false bash; echo "exit $?"
   ```

2. On the VM, read the two units and doctor:

   ```sh
   systemctl is-enabled devaloy-paseo devaloy-t3code; systemctl is-active devaloy-paseo devaloy-t3code; devaloy doctor >/dev/null; echo "doctor exit $?"
   ```

   - [ ] Both units show `disabled` and `inactive`, and the last line is `doctor exit 0`

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

**Reset.** No reset is necessary. Scenario 5 starts from this state.

## Scenario 5: VM installed, public sshd open

This scenario closes public SSH. Run it last. The provider console is your recovery route if you lock yourself out.

**Setup.** Run once, for every case in this scenario.

1. On the laptop, open an SSH session to the VM over the public address:

```sh
ssh ubuntu@$VM_IP
```

- [ ] Setup complete

### TC-5.1: `--lockdown` from a public IP refuses  ·  🔴 Critical

**Goal.** `--lockdown` never cuts off the session that runs it.

**Steps**

1. In the public session, run the one-liner with `--lockdown`:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/issue-4-install-devaloy-natively-on-an-ubuntu-vm/scripts/install-native.sh | sudo DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm bash -s -- --lockdown; echo "exit $?"
   ```

   - [ ] The command refuses with "not a tailnet address" and a non-zero exit
2. In the public session, read the firewall:

   ```sh
   sudo ufw status
   ```

   - [ ] The output shows `Status: inactive`

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-5.2: `--lockdown` over the tailnet closes public SSH  ·  🔴 Critical

**Goal.** Over the tailnet, `--lockdown` allows only `tailscale0`, and a second run sees it is already done.

**Steps**

1. On the laptop, check if a Tailscale SSH session carries `SSH_CONNECTION`:

   ```sh
   ssh dev@devaloy-vmtest 'echo "${SSH_CONNECTION:-<empty>}"'
   ```

   - [ ] Write the output in **Notes**. If it is `<empty>`, the next step refuses, and that is a known gap, not a failure of this case
2. On the laptop, run the one-liner with `--lockdown` over the tailnet:

   ```sh
   ssh dev@devaloy-vmtest 'curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/issue-4-install-devaloy-natively-on-an-ubuntu-vm/scripts/install-native.sh | sudo DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm bash -s -- --lockdown; echo "exit $?"'
   ```

   - [ ] The command prints `exit 0`, and `sudo ufw status verbose` shows deny incoming with only `tailscale0` allowed
3. On the laptop, try the public address:

   ```sh
   ssh -o ConnectTimeout=10 ubuntu@$VM_IP true; echo "exit $?"
   ```

   - [ ] The connection times out with a non-zero exit, and `ssh dev@devaloy-vmtest true` still works
4. On the laptop, run step 2 again.
   - [ ] The installer prints "already locked down" and exits 0

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _SSH_CONNECTION value: ___ ; what actually happened on a fail; why it was skipped_

**Reset.** Destroy the VM. Remove `devaloy-vmtest` from the Tailscale admin console.

## Automated verification (by AI agent)
_Checks the agent ran itself. No action needed from the tester; listed here for context and sign-off._

Commands run on 2026-10-29 at `e9f7ed5` with the current uncommitted changes:

```sh
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:stable -x entrypoint.sh devaloy lib/common.sh lib/doctor.sh lib/ram.sh lib/update.sh lib/steps/common.sh lib/steps/env.sh lib/steps/tailscale.sh lib/steps/docker.sh lib/steps/toolchain.sh lib/steps/git.sh lib/steps/paseo.sh lib/steps/t3code.sh lib/steps/native-boot.sh lib/steps/native-serve.sh scripts/install-native.sh scripts/host-firewall-lockdown.sh
```

```sh
bash -n scripts/install-native.sh
```

```sh
bash scripts/install-native.sh --help
```

```sh
bash scripts/install-native.sh </dev/null
```

```sh
docker run --rm -v "$PWD:/src:ro" ubuntu:22.04 bash /src/scripts/install-native.sh </dev/null
```

```sh
docker run --rm --device /dev/net/tun -v /home/dev/qa-snap.git:/repo.git:ro -v /home/dev/qa-snap/scripts/install-native.sh:/i.sh:ro -e DEVALOY_SRC=/repo.git -e DEVALOY_REF=issue-4-install-devaloy-natively-on-an-ubuntu-vm ubuntu:24.04 bash /i.sh </dev/null
```

- ✅ shellcheck on all 18 changed shell files → exit 0, no findings
- ✅ `bash -n` on the same 18 files → 0 syntax errors
- ✅ `install-native.sh --help` → exit 0, usage text names `--no-wait`, `--lockdown`, `--cli-only` and every env variable
- ✅ installer as a non-root user → exit 1, `Run as root: curl -fsSL ... | sudo bash`
- ✅ installer on Ubuntu 22.04 → exit 1, `This installer supports Ubuntu 24.04 only (found ubuntu 22.04).`
- ✅ installer on Ubuntu 24.04 with no systemd as PID 1 → exit 1, `systemd is not running as PID 1 here. The native install needs it; in a container, use docker compose instead.`, and no `/etc/devaloy` is written
- ✅ `host-firewall-lockdown.sh` as root in an Ubuntu 24.04 container, with stub `tailscale`, `ip` and `ufw`:
  - empty `SSH_CONNECTION` → exit 1, `Cannot tell where this session came from: SSH_CONNECTION is empty.`
  - empty `SSH_CONNECTION` with `ALLOW_NON_TAILNET=1` → exit 0, `ufw --force enable` runs
  - source `203.0.113.7` → exit 1, `This SSH session is from 203.0.113.7, which is not a tailnet address.`
  - source `100.64.12.34` → exit 0, `ufw --force enable` runs

Results from the build on 2026-10-28, on `e9f7ed5` with an earlier set of uncommitted changes. These were not re-run here. The files they cover have not changed since, except where noted.

- ✅ Container regression: the branch image and a `main` image boot with the same 13 `[entrypoint]` log lines, byte for byte. One file in `/home/dev` differs: `~/.agents/.skill-lock.json`, and only by two timestamps.
- ✅ Package lists: 244 packages in both images with default build args, and 441 in both with `WITH_BROWSER=true`.
- ✅ `systemd-analyze verify` on the five unit files → exit 0.
- ✅ Installer smoke test with stub `systemctl` and `journalctl`: the no-key refusal, the failure with a fake key and its recovery hint, a second run that changes no file, env-file precedence, the Docker range probe, flags turned off, `--no-wait`, `devaloy update` on a branch and on a tag, and five `--lockdown` source cases. The lockdown script changed after this run. The four lockdown cases above re-test it.
- ✅ Docs: all 130 code spans and code lines in `docs/wiki/install-on-a-vm.md` appear in the code, or they are standard commands. All relative links resolve.

## Not covered / needs human judgment
- Real systemd ordering, a real reboot, a real `tailscale up`, native Docker, Chromium on the VM, and real ufw. No container on this box can boot systemd without `--privileged`. Scenarios 2 to 5 cover them on the VM.
- A Tailscale IPv6 source address in `SSH_CONNECTION`. The lockdown script refuses it. This plan does not test it.
- Two copies of `lib/`: when the VM also has a clone at `~/projects/devaloy`, `devaloy update` copies `lib/` from that clone. This plan does not test that case.
- A redeploy of the live box `devaloy-ovh` from this branch. The container regression above covers the boot path. A live redeploy happens after merge.
- Accessibility, compatibility and browser checks: the feature has no UI.
- Performance: the plan sets no time target. TC-2.3 records the install time for the plan's Context.

## Overall result
_Tick one when you finish the run, or skip the ticks. Report each failure in the agent session or as a PR comment, and the agent records it here._

- [ ] Pass: every case passed
- [ ] Fail: at least one case failed
- [ ] Partial: cases were skipped or not reached

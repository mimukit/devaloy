# QA Plan: devaloy container healthcheck

_Generated 2026-10-25 · against `923c1df` (clean) · covers issue #2: `devaloy health`, the Dockerfile `HEALTHCHECK`, the `WITH_DOCKER` runtime flag, and the docs_

## Summary
- The image defines a Docker healthcheck that runs `devaloy health`, so Docker and Beszel show devaloy as healthy or unhealthy.
- Working means the box reads healthy when Tailscale runs, unhealthy within about 90 s when Tailscale stops, and the container never restarts because of it.

## Environment
True for the whole plan. Do this once, before Scenario 1.

- Host: brainaloy-ovh, Docker Engine 29.9.1, Beszel hub on the same host.
- Build under test: the merged branch `issue-2-report-devaloy-health-to-docker`, or the branch itself before the merge.
- Run every command below on the Docker host, not over Tailscale SSH. TC-1.2 stops Tailscale, which ends any SSH session to the box.
- Run the commands from the directory that holds `docker-compose.yml`. Under Dokploy, use its **Deploy** button with **Rebuild** ticked instead of the command.

Redeploy with:

```sh
docker compose up -d --build
```

- [ ] Environment ready

## Test cases at a glance

Priority legend: 🔴 Critical · 🟡 Normal · 🟢 Low

| # | Scenario | Test case | Priority |
|------|----------|-----------|----------|
| TC-1.1 | 1: Box freshly redeployed on brainaloy-ovh | The box turns healthy after a boot, and Beszel shows it | 🔴 Critical |
| TC-1.2 | 1: Box freshly redeployed on brainaloy-ovh | A Tailscale outage turns the box unhealthy and restarts nothing | 🔴 Critical |
| TC-1.3 | 1: Box freshly redeployed on brainaloy-ovh | A frozen dockerd turns the box unhealthy | 🟡 Normal |
| TC-2.1 | 2: The PR diff is open | The docs read clearly | 🟢 Low |

## Scenario 1: Box freshly redeployed on brainaloy-ovh

**Setup.** Run once, for every case in this scenario.

1. Redeploy as **Environment** says.
2. Record the container start time. TC-1.2 and TC-1.3 compare against it.

```sh
docker inspect --format '{{.State.StartedAt}}' devaloy
```

- [ ] Setup complete

### TC-1.1: The box turns healthy after a boot, and Beszel shows it  ·  🔴 Critical

**Goal.** A normal boot reaches `healthy` within 2 minutes, and Beszel shows "Healthy".

**Steps**

1. Read the health state. Repeat every 15 s until it is not `starting`.

   ```sh
   docker inspect --format '{{.State.Health.Status}}' devaloy
   ```

   - [ ] The state is `healthy` within 2 minutes of the redeploy
2. Open the Beszel hub and find the `devaloy` container row.
   - [ ] The health column shows "Healthy", not "None"
3. Run the check by hand from your laptop over Tailscale SSH.

   ```sh
   ssh devaloy 'devaloy health; echo $?'
   ```

   - [ ] The output is `0` with no error line

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-1.2: A Tailscale outage turns the box unhealthy and restarts nothing  ·  🔴 Critical

**Goal.** With Tailscale down, the state turns `unhealthy`, the container keeps running, and recovery turns it `healthy` again.

**Steps**

1. Stop Tailscale inside the container. Your SSH sessions to the box end here.

   ```sh
   docker exec devaloy tailscale down
   ```

2. Wait 2 minutes. Then read the state, the restart count, and the start time.

   ```sh
   docker inspect --format '{{.State.Health.Status}} restarts={{.RestartCount}} started={{.State.StartedAt}}' devaloy
   ```

   - [ ] The state is `unhealthy`, `restarts=0`, and the start time equals the one from Setup
3. Read the last health log entry.

   ```sh
   docker inspect --format '{{json .State.Health}}' devaloy | jq '.Log[-1]'
   ```

   - [ ] The output names the fault: `devaloy health: tailscale backend is not Running`
4. Bring Tailscale back.

   ```sh
   docker exec devaloy tailscale up --ssh
   ```

   - [ ] Within 1 minute the state reads `healthy` again, and Beszel follows

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

### TC-1.3: A frozen dockerd turns the box unhealthy  ·  🟡 Normal

**Goal.** On a box built with `WITH_DOCKER=true`, a nested dockerd that stops answering turns the state `unhealthy`. Skip this case on a box built without Docker.

**Steps**

1. Freeze the nested dockerd.

   ```sh
   docker exec devaloy pkill -STOP dockerd
   ```

2. Wait 2 minutes. Then read the state and the last log entry.

   ```sh
   docker inspect --format '{{json .State.Health}}' devaloy | jq '{Status, last: .Log[-1].Output}'
   ```

   - [ ] The state is `unhealthy`, and the last output names `docker daemon is not answering`
3. Resume dockerd.

   ```sh
   docker exec devaloy pkill -CONT dockerd
   ```

   - [ ] Within 1 minute the state reads `healthy` again

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

**Reset.** Run after every case above. It confirms that Tailscale and dockerd run.

```sh
docker exec devaloy tailscale up --ssh
```

On a box built with Docker, also run:

```sh
docker exec devaloy pkill -CONT dockerd
```

## Scenario 2: The PR diff is open

**Setup.** Open the PR's **Files changed** tab.

- [ ] Setup complete

### TC-2.1: The docs read clearly  ·  🟢 Low

**Goal.** A reader learns what the health state means, and that it restarts nothing.

**Steps**

1. Read the changes in `README.md` and the five pages under `docs/wiki/`.
   - [ ] The text is clear and correct, and it agrees with itself
     - README "Managing the box": the new verb line and the paragraph under it
     - `manage-the-box.md`: the new `devaloy health` section
     - `recover-an-unreachable-box.md`: the `.State.Health` paragraph
     - `deploy-with-dokploy.md`: the Swarm and autoheal sentences in the Compose Type row
     - `architecture.md`: "How the box reports health"

**Result**

- [ ] Pass
- [ ] Fail
- [ ] Skipped

**Notes.** _what actually happened on a fail; why it was skipped_

## Automated verification (by AI agent)
_Checks the agent ran itself on devaloy (Engine with a nested daemon) at `923c1df`, clean. No action needed from the tester._

Commands run (one per block):

```sh
bash -n devaloy lib/doctor.sh lib/common.sh entrypoint.sh
```

```sh
DEVALOY_LIB=./lib ./devaloy health; echo $?
```

```sh
WITH_DOCKER=true DEVALOY_LIB=./lib ./devaloy health; echo $?
```

```sh
PATH=<stub dir>:$PATH WITH_DOCKER=true DOCKER_HOST=unix:///nonexistent.sock DEVALOY_LIB=./lib ./devaloy health; echo $?
```

```sh
WITH_DOCKER=false DOCKER_HOST=unix:///nonexistent.sock DEVALOY_LIB=./lib ./devaloy health; echo $?
```

```sh
DEVALOY_LIB=./lib ./devaloy -h
```

```sh
docker compose config -q
```

```sh
docker build -q -t devaloy-hc-test:issue-2 . && docker image inspect --format '{{json .Config.Healthcheck}}' devaloy-hc-test:issue-2
```

```sh
docker run -d --name qakit-hc --entrypoint sleep -e WITH_DOCKER=false --health-interval=2s --health-start-period=0s --health-retries=2 -v <stub>:/usr/local/bin/tailscale:ro devaloy-hc-test:issue-2 infinity
```

- ✅ C6 `bash -n` on the four changed scripts → exit 0
- ✅ C1 `devaloy health` on this box (Tailscale Running, dockerd up) → exit 0, no output; the same with `WITH_DOCKER=true` → exit 0
- ✅ C2 a stub `tailscale` that reports `NeedsLogin`, and `DOCKER_HOST` at a missing socket → two stderr lines (`tailscale backend is not Running`, `docker daemon is not answering`), exit 1
- ✅ C2 a stub `tailscale` that sleeps 30 s (checked at the Phase 1 commit, same `lib/doctor.sh`) → the Tailscale line after 5 s, exit 1
- ✅ C3 `WITH_DOCKER=false` with an unreachable daemon → exit 0, the Docker probe is skipped
- ✅ C4 `devaloy -h` → lists `devaloy health` once; the last line is still `can grep for the capability checks CLAUDE.md spells out in prose.`
- ✅ C5 `entrypoint.sh:504` writes `WITH_DOCKER=%s` to the runtime flags file; the comments in `entrypoint.sh`, `lib/common.sh` and `lib/doctor.sh` name it
- ✅ C7, C9 the image builds; `.Config.Healthcheck` → `["CMD","/usr/local/bin/devaloy","health"]`, interval 30 s, timeout 10 s, start period 180 s, start interval 5 s, retries 3
- ✅ C9 `devaloy health` in a bare container of the image, as root with no tailscaled → `tailscale backend is not Running`, exit 1 (checked at the Phase 2 commit, same image content)
- ✅ C9 Docker tracks the state: a container with a stub that reports `Running` → `healthy`; the stub flipped to `NeedsLogin` → `unhealthy restarts=0 running=true`
- ✅ C8 `docker compose config -q` → valid; the comment above `restart: unless-stopped` says health does not drive restarts
- ✅ C10 to C14 `grep` → `devaloy health` appears in `README.md`, `architecture.md`, `manage-the-box.md`, `recover-an-unreachable-box.md` and `reference.md`; the README says an unhealthy box is never restarted; `deploy-with-dokploy.md` names `AUTOHEAL_CONTAINER_LABEL=all`; the recover page shows `.State.Health`; `architecture.md` names the `HEALTHCHECK`

## Not covered / needs human judgment
- The real Tailscale and Beszel behavior on brainaloy-ovh. The agent has no access to that host, so Scenario 1 stays manual.
- A cold first boot on an empty home volume. The check does not use mise, so the bootstrap cannot delay it, but no run confirmed this on a cold volume.
- Compatibility, accessibility, and UI: the change has no UI.
- Concurrency and performance: the probe runs once per 30 s and took 19 ms on this box, so no load case applies.
- Security: the probe reads local state only and prints no secret.

## Overall result
_Tick one when you finish the run, or skip the ticks. Report each failure in the agent session or as a PR comment, and the agent records it here._

- [ ] Pass: every case passed
- [ ] Fail: at least one case failed
- [ ] Partial: cases were skipped or not reached

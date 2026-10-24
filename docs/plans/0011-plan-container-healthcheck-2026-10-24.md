# Plan: a Docker healthcheck for the devaloy container
Grilled: 2026-10-24

Drafted: 2026-10-24

## Context

Beszel on the brainaloy-ovh VPS shows the `devaloy` container with health "None". The image has no `HEALTHCHECK` and `docker-compose.yml` has no `healthcheck:` key, so Docker records no health state for it. The other stacks on that host (WordPress, Postgres, cloudflared, Tailscale, the Beszel hub) define healthchecks and show "Healthy".

The goal behind the request is an honest signal: the dashboard should say when the box is unreachable, and only then. The box must never restart because of that signal, since a restart kills every running agent session.

Target: Beszel shows "Healthy" for devaloy within 2 minutes of a boot, and "unhealthy" within about 90 s of Tailscale going down, with no change to the container start time.

What healthy means here, from the code:

- PID 1 is tini (`init: true`). `entrypoint.sh` ends with `wait "${TAILSCALED_PID}"`, so the container lives as long as tailscaled does.
- There is no sshd (`Dockerfile:282`). Tailscale SSH is the only way in. tailscaled starts first, and `tailscale up --ssh --timeout=90s` runs before anything slow (`entrypoint.sh:292-344`).
- A failed `tailscale up` is non-fatal on purpose. The container stays up and is unreachable. That is the main fault the check has to catch.
- dockerd starts only when the env `WITH_DOCKER=true` and `/usr/bin/dockerd` exists (`entrypoint.sh:374-456`). A supervisor loop restarts it after a 10 s sleep.
- `WITH_BROWSER` adds shared libraries and no process, so there is nothing to probe at runtime.
- The mise bootstrap runs after tailscale and dockerd and can take minutes on a cold volume.
- `devaloy doctor` already separates "off by flag" from "broken" (`lib/doctor.sh`, with `runtime_flag` in `lib/common.sh:300-307`). It is too broad for a healthcheck: it also checks fzf, the mise shims and `GITHUB_TOKEN`, and the shims row reads `$HOME`, which is `/root` inside a healthcheck exec.
- No shell on the box inherits PID 1's environment. `printenv WITH_DOCKER` in an SSH shell prints nothing, and `/opt/devaloy/runtime-flags` records `WITH_PASEO`, `WITH_BROWSER` and `WITH_T3CODE` but not `WITH_DOCKER` (`entrypoint.sh:498-501`). A healthcheck exec does get the container environment.
- Measured on this box (Tailscale 1.104.2): `tailscale status --json | jq -e '.BackendState == "Running"'` exits 0 in 19 ms.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Meaning of "healthy" | The box is reachable: Tailscale runs, and the nested dockerd answers where the entrypoint starts it. A failed toolchain bootstrap is still healthy; `devaloy doctor` reports it and `devaloy update` repairs it. (asked, Q1) |
| Paseo and T3 Code | Out of the check, also when their keys are on. `devaloy doctor` reports them. (asked, Q2) |
| Tailscale probe | `timeout 5 tailscale status --json \| jq -e '.BackendState == "Running"'`. Any other state (`NeedsLogin`, `Stopped`, `Starting`), a dead socket or a 5 s stall fails. `.Health` warnings and `.Self.Online` are ignored, because they change during a DERP or control-plane outage while existing connections still work. (defaulted, Q6 and Q7) |
| Docker probe gate | `timeout 5 docker info` runs only when `runtime_flag WITH_DOCKER` is `true` and `/usr/bin/dockerd` is executable. This is the entrypoint's own start condition. `build_flag` is not used, so an old image whose flag reads `unknown` needs no special case. Every other combination passes. (defaulted, Q4) |
| `WITH_DOCKER` in runtime-flags | `entrypoint.sh` adds `WITH_DOCKER` to the `printf` that writes `/opt/devaloy/runtime-flags`, so `devaloy health` in an SSH shell gives the same result as the healthcheck. (defaulted, Q5) |
| Shape of the check | A quiet verb, `devaloy health`, in `lib/doctor.sh`. One stderr line per failure, exit 0 or 1. It reuses `runtime_flag`. No new module, so `DEVALOY_MODULES` does not change. |
| Where it is defined | A Dockerfile `HEALTHCHECK`. Every way to start the image gets it: the main stack, a second `DEVALOY_NAME` stack, Dokploy, plain `docker run`. Compose can still override it. |
| Timing | `--interval=30s --timeout=10s --start-period=3m --start-interval=5s --retries=3`. The start period covers `tailscale up` (90 s) and the dockerd wait (30 s). The bootstrap needs no cover because the check does not use mise. |
| `--start-interval` support | Needs Engine 25 or later. brainaloy-ovh runs Engine 29.9.1 (checked 2026-10-24). |
| Restart on unhealthy | None. `restart: unless-stopped` reacts to exit, not health. No `depends_on` exists. Dokploy runs the Compose type, not Stack (`docs/wiki/deploy-with-dokploy.md:80`), and only Swarm replaces unhealthy tasks. No autoheal container runs on brainaloy-ovh (checked 2026-10-24). |
| Test approach | No test runner exists in the repo. `bash -n` on each changed script, then the manual checks in each phase. (defaulted, Q8) |
| Outward actions | None by the build. The build leaves changes uncommitted; the owner commits. The redeploy on brainaloy-ovh is the owner's, in Phase 4. (defaulted, Q9; asked, Q3) |

Rejected: an inline shell line in `HEALTHCHECK` (no way to run it by hand, logic duplicated from `doctor`), and a compose `healthcheck:` key (the probe depends on what the image contains, so it belongs with the image).

## Approach

Add `devaloy health` next to `devaloy doctor`, record `WITH_DOCKER` in the runtime flags file, point a Dockerfile `HEALTHCHECK` at the verb, and document it. The binaries the verb calls (`bash`, `jq`, `tailscale`, `timeout`, and `docker` when built in) all come from apt in the image, none from mise.

Phases 1 to 3 can run unattended. Phase 4 needs the owner on the Docker host, because it redeploys the box and its fault test cuts Tailscale SSH. It comes last because it verifies the built image.

### Phase 1: the `devaloy health` verb (#2)

- `lib/doctor.sh`: add `do_health` with the two probes from the decisions table. Print one stderr line per failure. Return 0 or 1.
- `devaloy`: add `health` to both dispatch `case` blocks and one line to the header usage block. `usage()` prints `sed -n '2,35p'`, so move the end of that range down by one.
- `entrypoint.sh`: add `WITH_DOCKER=%s` to the runtime-flags `printf` at line 498, and update the comment above it and the matching comment in `lib/doctor.sh` that lists the runtime keys.

Done when: `bash -n devaloy lib/doctor.sh entrypoint.sh` prints nothing; `DEVALOY_LIB=./lib ./devaloy health; echo $?` prints `0` on this box; `DEVALOY_LIB=./lib ./devaloy -h` lists `health` and its last line is the last usage line.

### Phase 2: the Dockerfile `HEALTHCHECK` (#2)

- `Dockerfile`: add, after the build-flags `RUN` and before `ENTRYPOINT`:

  ```dockerfile
  HEALTHCHECK --interval=30s --timeout=10s --start-period=3m --start-interval=5s --retries=3 \
      CMD ["/usr/local/bin/devaloy", "health"]
  ```

  Add a comment block in the file's style that says what it probes, why mise is out of it, and that unhealthy restarts nothing.
- `docker-compose.yml`: add a short comment next to `restart: unless-stopped` that points to the Dockerfile and says health does not drive restarts.

Done when: `docker build` of the repo succeeds on this box (it has a daemon), and `docker image inspect --format '{{json .Config.Healthcheck}}' <image>` shows the command and the five timings.

### Phase 3: docs (#2)

- `README.md`, "Managing the box": add `devaloy health` to the verb list, and one sentence that the image defines a healthcheck and that unhealthy never restarts the box.
- `docs/wiki/reference.md`, verb table near line 224: add a `health` row with its exit codes and how it differs from `doctor`.
- `docs/wiki/manage-the-box.md`: one line next to the `doctor` exit codes.
- `docs/wiki/recover-an-unreachable-box.md`, "First response": add the `docker inspect ... .State.Health` command, and say that a `tailscale` line in `.Log` points to the Tailscale section.
- `docs/wiki/deploy-with-dokploy.md`: one sentence that the healthcheck is another reason to keep the Compose type, and that an autoheal container with `AUTOHEAL_CONTAINER_LABEL=all` would restart devaloy when unhealthy.
- Run a wikikit update pass for `docs/wiki/architecture.md`, which maps `Dockerfile` and `lib/**`.

Done when: `grep -rln 'devaloy health' README.md docs/wiki` lists `README.md`, `reference.md`, `manage-the-box.md` and `recover-an-unreachable-box.md`, and `grep -n healthcheck docs/wiki/deploy-with-dokploy.md` finds the new sentence.

### Phase 4: deploy and verify on brainaloy-ovh
Attended: the owner commits, redeploys with a rebuild, and runs the fault tests from the Docker host.

- Redeploy with `docker compose up -d --build`, or in Dokploy with Rebuild ticked.
- Run the checks below from the Docker host, because `tailscale down` cuts the SSH session.

Done when: `docker inspect --format '{{json .State.Health}}' devaloy | jq .Status` prints `"starting"` and then `"healthy"` within 2 minutes of the boot; `docker exec devaloy tailscale down` turns it `"unhealthy"` within about 90 s while `docker inspect --format '{{.State.StartedAt}}' devaloy` stays the same; `docker exec devaloy tailscale up --ssh` brings it back to `"healthy"`; on a `WITH_DOCKER=true` box, `docker exec devaloy pkill -STOP dockerd` fails the check and `pkill -CONT dockerd` restores it; `ssh devaloy 'devaloy health; echo $?'` prints `0`; the Beszel row for devaloy shows "Healthy" in place of "None".

## Open questions

None. Every decision from the 2026-10-24 grill is settled.

## Non-goals

- Paseo and T3 Code in the healthcheck. Each can fail without making the box unreachable, and `devaloy doctor` reports them.
- The toolchain bootstrap in the healthcheck.
- Any automatic restart on unhealthy, including an autoheal container.
- Alerts. Beszel shows the state; notifications are a separate decision.

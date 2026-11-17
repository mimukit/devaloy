# Plan: Claude usage in T3 Code on a token box
Grilled: 2026-11-17

## Context

A box that signs in to Claude with `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) shows no Claude group in the T3 Code Usage → Limits modal. A hand-made proof of concept on this box fixed that on 2026-11-17: a small Node server (`~/.local/bin/t3-usage-hub`) answers the two "cliproxy" management calls that T3 v0.1.10 makes, and a hand-written `usageLimitSources` entry in `~/.t3/userdata/settings.json` points T3 at it. The modal then showed 85% session and 64% weekly left, the same numbers as `usage --json`.

The proof of concept has two problems. Nothing in the repo starts it, writes the settings entry or checks it, so it dies with the next redeploy. And its data comes from the `usage` curl probe: a 1-token Haiku request that sends the subscription OAuth token with a "You are Claude Code" system prompt, from `curl` and not from the Claude Code binary. Anthropic's terms (https://code.claude.com/docs/en/legal-and-compliance, "Authentication and credential use") reserve OAuth login for "ordinary use of Claude Code and other native Anthropic applications" and allow enforcement "without prior notice". A plain `usage` (alias `u`) runs that probe today whenever its cache is older than 120 s, so the risk is already on the box.

The goal is Claude limits in T3 Code on every token-authenticated devaloy container, turned on by one variable, with no request to Anthropic that a person did not ask for.

Target: with `WITH_T3CODE_PROXY_CLAUDE_USAGE=true` on a token box, the Limits modal shows a Claude group whose numbers equal `usage --json`, and the hub and a plain `usage` send zero requests to `api.anthropic.com` (the code has no network call outside `--fetch` and `--curl`, and a hub run under `strace -f -e trace=connect` shows no connect other than the loopback accept).

## Research findings

These findings, checked on 2026-11-17 against Claude Code 2.1.326, T3 v0.1.10 (`~/.t3/runtime/versions/0.1.10/t3`) and the T3 data on this box, drive the design.

- **Why T3 shows nothing.** T3 already gets the numbers and drops them. Claude Code sends a `rate_limit_event` on each turn, and the numbers sit in `rate_limit_info.unifiedWindows.{five_hour,seven_day}.utilization` (a fraction). T3's `claudeRateLimitEventToUpdate` returns nothing unless a top-level `utilization` is present, and Claude Code sets that field only near a warning threshold. At start T3 also sends the SDK `get_usage` request. Claude Code answers `rate_limits_available: false`, because `Ru()` needs the `user:profile` scope and a setup-token has `user:inference` only. T3 then marks Claude `unsupported`, and `applyUsageLimitsUpdate` drops every later update.
- **Upstream knows.** pingdotgg/t3code#24114 (open, 2026-10-23) reports this exact bug. Open PRs #24128 ("show limits for Claude setup-token accounts") and #31135 ("streamed usage limits survive a failed probe") fix it. No new issue is needed.
- **T3 logs the events.** T3 writes every Claude SDK message to `~/.t3/userdata/logs/provider/events.<thread>.log`, one `[<ISO time>] <tag>: {json}` line each. This box has 425 `rate_limit_event` lines with both windows. That is a cache source that costs zero requests.
- **The key is a T3 secret.** T3 v0.1.10 moved the literal `managementKey` of the hand entry to `~/.t3/userdata/secrets/usage-limit-source-<base64(id)>.bin` (mode 0600, the raw key) and wrote `"••••••"` in `settings.json`.
- **T3 moves inline secrets on every load.** `loadSettingsFromDisk` calls `moveInlineSettingsSecrets`, which puts each non-empty inline secret into the secret store and rewrites `settings.json` with the placeholder. This runs on every load, not only on a save from the app.
- **T3 watches `settings.json`.** `startWatcher` reloads the file within 100 ms of a change (`fs.watch` on the directory, debounced). An outside write while T3 runs is read, not overwritten.
- **`claude -p` without hooks.** `--safe-mode` turns off hooks, CLAUDE.md, MCP servers, plugins and skills, and keeps OAuth. `--bare` is not usable: it never reads OAuth.
- **Log scan cost.** A newest-first scan for the last `rate_limit_event` across the 33 `events.*.log` files (60 MB) on this box takes 15 ms.
- **No test runner.** The repo has no test directory and no CI. Shell files carry `shellcheck` directives.
- **`usage` already ships.** `config/bin/usage` is byte-identical to `~/.local/bin/usage`, and `step_seed_config` (`lib/steps/env.sh`) copies `config/bin/` to `~/.local/bin/` on each boot. `alias u='usage'` is in `config/zsh/zshrc`.

## Alternatives

Each source checked for this plan. "Requests" means requests to Anthropic that the source adds.

| Source | Works with a setup-token | Data age | Requests | Account risk | Effort | Verdict |
|---|---|---|---|---|---|---|
| Upstream T3 fix (#24128, #31135) | Yes: the events carry the numbers (seen in this box's logs) | Last T3 Claude turn | 0 | None | None for us, wait for a release | Best end state. Phase 8 removes the hub after it ships |
| T3 provider logs read by `usage` | Yes, 425 events on this box | Last T3 Claude turn | 0 | None | Small. A log format change gives "no reading", not a wrong number | Chosen, cache source 1 |
| Status line input (`rate_limits.five_hour/seven_day`) | Yes, `config/claude/statusline.sh` already mirrors it to `~/.claude/usage-live-cache.json` | Last render of an interactive `claude`. It does not run in SDK turns: the cache did not change during this T3 session's turns | 0 | None | Done | Kept, cache source 2 |
| `~/.claude.json` `cachedUsageUtilization` | Only after `/login`; a token box never writes it | Last login session | 0 | None | Done | Kept, cache source 3 |
| Hook input (`Stop`, `PostToolUse`, `Notification`, `StopFailure`) | No. The schemas in the binary have no rate-limit fields; `StopFailure` carries the error type only | n/a | n/a | n/a | n/a | Rejected |
| SDK `get_usage` | No. `rate_limits` is null without `user:profile`; #24114 reports HTTP 429 when the scope is forced with `CLAUDE_CODE_OAUTH_SCOPES` | n/a | n/a | n/a | n/a | Rejected |
| `/api/oauth/usage` with the token | No, refused (the original problem) | n/a | n/a | n/a | n/a | Rejected |
| Real binary: `claude -p --output-format stream-json` | Yes, per #24114; the event arrives even when the window is exhausted | On demand | 1 small Haiku turn per reading | Lower than curl because it is the real client, but still automated use that spends tokens | Small | Chosen as manual `usage --fetch` only |
| Current curl probe | Yes | On demand | 1 per run | Highest: a request that claims to be Claude Code and is not | Done | Kept only as manual `usage --curl` |

Recommendation: cache-only by default (sources 1 to 3, newest wins), manual `--fetch` and `--curl` for a person who wants a live reading, and removal of the hub once T3 ships the upstream fix.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Variable | One runtime variable, `WITH_T3CODE_PROXY_CLAUDE_USAGE`, default `false`, like `WITH_PASEO`: `docker compose up -d` picks up a change, no rebuild. It does nothing unless `WITH_T3CODE=true`. No second variable: the hub never fetches. |
| Hub fetch | Never. The hub runs `usage --json` with no fetch flag. The Limits modal can show old numbers. T3 shows the reading time, and the docs say so. |
| `usage` default | A plain `usage` (and `--line`, `--json`) reads the three caches and sends no request. The automatic 120 s probe, `USAGE_PROBE_MAX_AGE` and `USAGE_NO_FETCH` go. `--no-fetch` stays accepted as a no-op so old callers do not break. |
| `usage --fetch` | Runs the real binary: `claude -p --safe-mode --no-session-persistence --strict-mcp-config --model haiku --output-format stream-json --verbose` with a one-word prompt. `--safe-mode` keeps `agent-push` and every other hook from running. Reads the first `rate_limit_event`, writes the result to `~/.claude/usage-live-cache.json`, then prints. (grill Q4, defaulted) |
| `usage --curl` | The current curl probe, unchanged, behind its own flag. The help text names the account risk. |
| Fetch floor | `--fetch` and `--curl` refuse to run when the newest reading from any source is under 60 s old. They print `usage: newest reading is <n> s old (<source>); use --force to fetch anyway` and exit 3. `--force` skips the check. (grill Q1, asked) |
| T3 log source | `usage` reads `${T3CODE_HOME:-~/.t3}/userdata/logs/provider/events.*.log` files modified in the last 7 days. From each file it takes the last `rate_limit_event` line that has `unifiedWindows` and comes from the default `claudeAgent` provider instance. The newest line time across the files wins (not the newest file mtime). Fractions become percent. A window absent from `unifiedWindows` reads as `-`, not 0. A parse failure means "no reading from this source". (grill Q5 and Q6, defaulted) |
| `usage --json` shape | Keeps `{fetchedAtMs, utilization:{five_hour, seven_day}}` and adds `source` and, per window, `reset_inferred` when the reset rule set it to 0. (grill Q8, defaulted) |
| Reset rule | When a window's `resets_at` is in the past, `usage` reports it as 0% with the reset time unknown, in every output mode. The window has reset, so 0 is correct for this machine. |
| Names | Hub: `config/bin/t3-claude-usage-proxy` (Node, no dependencies), seeded to `~/.local/bin` by `step_seed_config`. Boot step file: `lib/steps/t3-claude-usage.sh`. Settings entry id: `devaloy-claude-usage`. Glossary term: Claude usage proxy. |
| Label in T3 | `"label": "Claude (token)"`. (grill Q2, asked) |
| Runtime | Container only. The supervisor is a restart loop in `entrypoint.sh` beside the T3 loop. The step file stays runtime-neutral so a later plan can call it from `native-boot.sh` and `upstash-boot.sh`. |
| Start order | The step runs after `step_t3code_projects` and before the T3 loop starts. T3 would also pick up a later write through its file watcher, but a write before start cannot race a save from the app. The hub loop starts before the T3 loop. |
| Settings write | `jq` changes only `.usageLimitSources["devaloy-claude-usage"]`. Before a change, the step copies the file to `settings.json.devaloy-bak`. It writes a temp file in the same directory and `mv`s it, with the old mode and owner. Invalid JSON: log a warning, write nothing. No change needed: write nothing, so the mtime stays. |
| Key | The boot step creates `~/.config/t3-claude-usage-proxy/key` (48 hex chars, dir 0700, file 0600) when absent. The hub reads it and never creates it. |
| Key handoff to T3 | The step writes the literal key into the entry. T3 moves it to its secret store on start. On later boots, the entry is left alone when it has the right `kind`, `url` and `enabled`, and `secrets/usage-limit-source-<base64("devaloy-claude-usage")>.bin` equals the key file. Otherwise the step writes the literal key again. The step only reads T3's secret file, never writes it. |
| Flag off | The step deletes the `devaloy-claude-usage` entry and does not start the hub. Other entries and keys stay. T3's secret file for the entry stays too, because devaloy never writes T3's secret store. (grill Q7, defaulted) |
| `/login` box | When `CLAUDE_CODE_OAUTH_TOKEN` is empty, the step removes the entry, does not start the hub and logs a warning. T3 reads Claude limits natively on such a box, so the entry would show Claude twice. |
| Hub behaviour | Binds `127.0.0.1:8317` only. Answers `GET /v0/management/auth-files` and `POST /v0/management/api-call` like the proof of concept. Logs start-up, errors and every 404 or 401 with method and path, and no line for a normal request. An `api-call` for any URL other than `/api/oauth/usage` answers `status_code: 404`. A `usage` failure answers `status_code: 502`, so T3 shows no Claude numbers rather than wrong ones. |
| Log | `/var/log/devaloy-claude-usage-proxy.log`, like `/var/log/devaloy-db-forward.log`. No rotation: the hub logs only start, errors, 401 and 404, and `/var/log` resets with the container. (grill Q11, defaulted) |
| Contract check | `devaloy doctor` calls the hub with the key exactly as T3 does and checks the shapes. It also reads the T3 entry, and compares `t3 --version` with `T3_CLAUDE_USAGE_TESTED=0.1.10` in the step file. A version that differs is a warning, not broken, because T3 ships nightlies. (grill Q9, defaulted) |
| Duplicate group after the upstream fix | No detection. The version warning above prompts a look after each T3 update, and Phase 8 removes the hub. T3 gives devaloy no signal that its own Claude group works. (grill Q10, defaulted) |
| Fail safe | A changed T3 contract can only blank the Claude group. The hub listens on loopback only and sends nothing out. |
| Checks | No test runner is added. Each build phase runs `shellcheck` on the shell files it changes and `node --check` on the hub, then the commands in its `Done when:` line. After Phase 6, `qakit` writes a QA plan under `docs/qa/` that collects those commands. (grill Q12, defaulted) |
| Outward actions | Phase 1 is a 👍 reaction on pingdotgg/t3code#24114, added by the owner by hand, plus a subscribe. No agent posts on GitHub. Phase 7 restarts this box's container. (grill Q3 and Q13, asked) |

## Approach

The work reuses the proof of concept files as the reference, `config/bin/` with `step_seed_config` for delivery, the `step_runtime_flags` writer (`lib/steps/toolchain.sh`) for the flag, the db-forward pattern (`lib/steps/db-forward.sh` plus a loop in `entrypoint.sh`) for a small supervised process, the `jq` merge style of `step_paseo_config` (`lib/steps/paseo.sh`), and the row helpers in `lib/doctor.sh` and `lib/status.sh`.

Rejected: a systemd-style `nohup` helper like `t3-usage-hub-start` (the entrypoint loop already is the supervisor); a T3 secret file written by devaloy (it ties writes to a private T3 format); two variables (the hub never fetches, so a probe variable has no job).

### Phase 1: upstream reaction
Attended: the owner adds the reaction and subscribes from their own GitHub account. The build does not wait for this phase.

- Add a 👍 reaction to the body of pingdotgg/t3code#24114.
- Subscribe to the issue, so its close shows when Phase 8 can start.

Done when: the reaction from the owner's account shows on #24114.

### Phase 2: `usage` reads three caches and fetches only on request (built 2026-11-17)

- Add the T3 log source per the design row. Keep the existing `~/.claude.json` and status line sources. Newest reading wins. The footer names the source: `t3 log`, `statusline cache`, `account cache`, `live (claude -p)`, `live (curl)`.
- Remove the automatic probe, `USAGE_PROBE_MAX_AGE` and `USAGE_NO_FETCH`. Keep `--no-fetch` as a no-op.
- Add `--fetch` (real binary) and `--curl` (old probe). Both write the status line cache and then print in the chosen mode.
- Add the 60 s fetch floor and `--force`.
- Add the reset rule.
- Update the help block. It names the account risk of `--fetch` and `--curl`.

Done when:
- `usage --json` on this box prints the newest of the three sources with its `source`, and `strace -f -e trace=connect usage --json` shows no connect.
- With the status line cache moved away, `usage --json` returns the newest `rate_limit_event` from the T3 logs, with percents equal to 100 × the `unifiedWindows` fractions.
- `usage --fetch --force` prints `live (claude -p)`, `~/.claude/projects` gets no new session file, and no ntfy message arrives.
- A second `usage --fetch` within 60 s prints the floor message and exits 3.
- A test cache with `resets_at` in the past prints 0% for that window, and `--json` marks it `reset_inferred`.

### Phase 3: the hub (built 2026-11-17)

- Add `config/bin/t3-claude-usage-proxy` from the proof of concept with the design changes: the key file path, no key creation, the logging rule, a plain `usage --json` call.
- Keep `T3_USAGE_HUB_PORT`-style overrides under the new names: `T3_CLAUDE_USAGE_PROXY_PORT`, `T3_CLAUDE_USAGE_PROXY_CMD`.

Done when: with the hub running by hand, `curl -H "Authorization: Bearer $(cat ~/.config/t3-claude-usage-proxy/key)" 127.0.0.1:8317/v0/management/auth-files` returns one `provider:"claude"` file, the `api-call` POST for `/api/oauth/usage` returns `status_code:200` with a `body` whose numbers equal `usage --json`, a wrong key returns 401, and the log holds only the start line and the 401 line.

### Phase 4: the boot step and the flag (built 2026-11-17)

- Add `lib/steps/t3-claude-usage.sh` with `step_t3_claude_usage_config` (token check, key file, settings entry or its removal) and `T3_CLAUDE_USAGE_TESTED`.
- Source it in `entrypoint.sh`. Call it in the T3 block after `step_t3code_projects`, also when the flag is off, so the entry goes away.
- Add the restart loop in `entrypoint.sh` before the T3 loop: same `oom_score_adj` slot, `as_dev`, log to `/var/log/devaloy-claude-usage-proxy.log`, 10 s restart.
- Add the key to `step_runtime_flags`, the `docker-compose.yml` environment list and `.env.example`.
- Update the "NO SETTINGS ARE WRITTEN" comment in `entrypoint.sh`: devaloy now writes one entry, and only with this flag.

Done when:
- A container start with the flag on and a token gives a listening hub, a `devaloy-claude-usage` entry, and the Claude group in the Limits modal with the `usage --json` numbers.
- A second start leaves `settings.json` mtime unchanged.
- A start with the flag off removes the entry and leaves every other key byte-equal (`jq -S 'del(.usageLimitSources["devaloy-claude-usage"])'` before and after).
- A start with an empty token removes the entry and logs the warning.
- A `settings.json` with broken JSON is left as it is, with a warning.

### Phase 5: status and doctor (built 2026-11-17)

- `devaloy status`: a `claude usage` line: off, or up with the source and the age of the reading.
- `devaloy doctor`: a `claude usage` row:
  - off when the flag is off, when `WITH_T3CODE` is off, or when there is no token, each with its reason.
  - broken when nothing listens on 8317, with the log path.
  - broken when the contract check fails, naming the call that failed.
  - broken when the entry is missing or disabled.
  - a warning when `t3 --version` differs from `T3_CLAUDE_USAGE_TESTED`, or when the log has 404 lines after the last start.
  - ok with the source and age otherwise.

Done when: each row state above shows on this box when its condition is set up by hand (stop the hub, edit the entry, set `T3_CLAUDE_USAGE_TESTED=0.0.0`, send an unknown path).

### Phase 6: docs (built 2026-11-17)

- `.env.example`: a block under `WITH_T3CODE` that explains the variable, the dependency on `WITH_T3CODE` and the token, the old-numbers behaviour, and that the box never fetches.
- `README.md`: a row in the variable table near line 435 and a paragraph in "(Optional) the T3 Code apps".
- `docs/wiki/reference.md`: rows for `usage` (with `--fetch` and `--curl` and their account risk) and `t3-claude-usage-proxy`.
- `CONTEXT.md`: a glossary entry for "Claude usage proxy" under "Tools and config".
- `config/claude/skills/devaloy-box/SKILL.md`: a short section: how an agent reads limits (`usage --json`), that it must not run `--fetch`, `--curl` or `--force` unless the human asks, and where the hub log is.

Done when: every file above names `WITH_T3CODE_PROXY_CLAUDE_USAGE` or `usage --fetch` where the row says, and no doc mentions `USAGE_PROBE_MAX_AGE` (`git grep USAGE_PROBE_MAX_AGE` is empty).

### Phase 7: migrate this box
Attended: it restarts the T3 server, which cancels running turns, and it deletes hand-made files.

- Stop the hand loop and `t3-usage-hub`.
- Delete `~/.local/bin/t3-usage-hub`, `~/.local/bin/t3-usage-hub-start` and `~/.config/t3-usage-hub/`.
- Remove the `local-claude` entry from `settings.json` and its secret file `usage-limit-source-bG9jYWwtY2xhdWRl.bin`, with a backup first.
- Set `WITH_T3CODE_PROXY_CLAUDE_USAGE=true` in the host `.env` and restart the container.

Done when: `pgrep -f t3-usage-hub` is empty, the Limits modal shows exactly one Claude group, labelled `Claude (token)`, and `devaloy doctor` shows the `claude usage` row ok.

### Phase 8: remove the hub after the upstream fix
Attended: waits on a T3 Code release that contains the fix for #24114.

- Upgrade T3 on this box and confirm the native Claude group shows on a token box.
- Make the boot step always remove the entry, and delete the hub, the loop, the doctor and status rows, and the variable docs. Keep the `usage` changes.

Done when: with the fixed T3 and no hub, the Limits modal shows Claude numbers that move after a T3 Claude turn.

## Migration and rollback

The plan changes a persisted file that T3 owns (`settings.json`). Phase 4 writes one key and backs the file up to `settings.json.devaloy-bak` before each change. Rollback is the flag: `WITH_T3CODE_PROXY_CLAUDE_USAGE=false` and a restart remove the entry. A bad write can be undone by copying the backup back while T3 is stopped. Phase 7 moves this box from the hand entry to the packaged entry, with its own backup.

## Open questions

None. The grill on 2026-11-17 closed all seven draft questions: four by facts in the binaries (see Research findings), three by decisions (fetch floor, secret file, duplicate group).

## Non-goals

- The native VM and the Upstash Box. The step file is runtime-neutral, but no supervisor or unit for them is in this plan.
- Any automatic request to Anthropic from the box.
- A new upstream issue. #24114 already covers the bug.
- Codex or other providers in the hub.
- More than one Claude account in T3. Only the default `claudeAgent` provider instance feeds `usage`.
- Changes to `config/claude/statusline.sh`.

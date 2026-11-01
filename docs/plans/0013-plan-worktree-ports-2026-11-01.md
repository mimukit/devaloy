# Plan: Hashed dev ports for parallel worktrees

Grilled: 2026-11-01

## Context

During a QA or review session, only one worktree of a project can run at a time. Most projects use the fixed ports 3000, 3001 and 4000, so a second dev server fails with "port in use". The owner then stops one checkout with `kp` before they start the next one.

Goal: several worktrees of the same project, or of different projects, run at the same time on the box. Each one opens in the laptop browser at `http://localhost:<port>`, and the frontend to API calls work with no hand edits.

Target: 3 linked primeshopr worktrees and the primeshopr main checkout run `pnpm dev` at the same time. Each web and admin app loads on the laptop, and an admin login holds in each worktree at the same time (proposed; baseline is 1 checkout at a time, stated by the owner on 2026-10-27).

The research is in the chat history only, by the owner's choice. The findings that this plan uses:

- `ssh -L` over Tailscale SSH works from the owner's laptop to the box (tested on 2026-11-01 with T3 Code on 3773).
- Cookies are not isolated by port (RFC 6265 §8.5), and this includes `localhost`.
- The forward must target a server that listens on `127.0.0.1` or `0.0.0.0`. A server that listens only on the tailnet address refuses the forwarded connection.
- Wrangler's `getDefaultEnvFiles` loads `.env` and then `.env.local`, and the Cloudflare Vite plugin 1.62.3 gets its vars through `wrangler.unstable_getVarsForDev`. The plugin watches only `.env` and `.dev.vars` for changes, so a change to `.env.local` needs a restart.
- Astro documents `loadEnv(process.env.NODE_ENV, process.cwd(), "")` for reading `.env` files in `astro.config.mjs`.

## Design decisions (settled)

| Decision | Resolution |
|----------|-----------|
| Routing | Ports only. No Caddy, no custom subdomain, no wildcard DNS. |
| Worktree tool | No Worktrunk. This plan takes only its branch-hash idea. |
| Port formula | `10000 + int(sha256("<repo>:<service>:<branch>")[:8], 16) % 10000`. `<repo>` is the main checkout's folder name. `<branch>` is the current branch, or the worktree folder name on a detached HEAD. |
| Main checkout | Keeps the project's default ports (primeshopr: 3000, 3001, 4000). The box command refuses to run there. |
| Service description | A committed `.devports.json` at each project's root. It lists the services with their default ports, and the env keys to write into each app's `.env.local`, as templates. devaloy stays generic. |
| Box command scope | `wtports` writes env values and prints URLs only. The owner starts the servers with the project's own `pnpm dev`. |
| How `wtports` runs | By hand, in each worktree, before `pnpm dev`. No gitkit `setup:` hook. |
| Env file ownership | `wtports` owns a marked block (`# >>> wtports` to `# <<< wtports`) in each `.env.local`. It keeps every line outside the block. |
| Port key | `DEV_PORT`, not `PORT`, because other tools read `PORT` and the Worker receives every key as a binding. |
| Collision | A port is taken when another worktree's block holds it, or when a listener holds it at run time. On a collision, `wtports` takes the next free port and writes it in the block with a comment, for example `DEV_PORT=16461  # hash 16460 taken by issue-91`. Later runs keep the port from the block. The worktree that ran first keeps its port. |
| Re-run | When the block is already current, `wtports` changes nothing and prints "no change". When the block changed, it says to restart `pnpm dev`. |
| CORS | Real CORS with values from the env (option 2). The API's allowed origins and the frontend's API URL come from the same ports. Always `localhost`, never `127.0.0.1`. |
| Laptop access | `wtforward` on the laptop keeps one SSH ControlMaster connection to the box. Every 2 seconds (`WTFORWARD_INTERVAL`) it reads the box's TCP listeners and adds or removes `ssh -O forward -L p:127.0.0.1:p` for each listener in 10000 to 19999, plus `WTFORWARD_EXTRA` (default `3000 3001 3002 4000`) for main checkouts. The port number is the same on both sides. |
| Laptop OS | macOS and Linux. The script uses only `sh` and `ssh`, and `ss` runs on the box. |
| Laptop install | `scp devaloy:projects/devaloy/scripts/wtforward ~/.local/bin/` |
| Two logins of one app | The cookie prefix comes from the env. `wtports` writes `AUTH_COOKIE_PREFIX=wt<slug>`, so the cookie becomes `wt<slug>-client.session_token`. When the key is unset, the names stay `client` and `admin`. |
| Language | `wtports` is Python 3, like `config/bin/kp`. `wtforward` is POSIX `sh`, because macOS has no Python 3 without the Command Line Tools. |
| Tests | No new test runner in devaloy. Phase 1 checks its result with a scripted scratch-repo run in its QA plan, as `kp` did. |
| primeshopr work | Filed in the primeshopr repo as its own issue, linked to this plan. This plan carries the file list in [primeshopr adoption](#primeshopr-adoption). |
| Outward actions | Approved on 2026-11-01: file one devaloy issue for each phase, and one primeshopr adoption issue, through issuekit. |

## Approach

The box command follows the pattern of `config/bin/kp`: a self-contained script that config sync copies into `~/.local/bin/`, documented in `docs/wiki/reference.md`. The primeshopr side reuses what is already there: `CORS_ORIGINS` (read by `hono/cors` in `apps/api/src/index.ts` and by `trustedOrigins` in `packages/auth/src/auth.ts`), `BETTER_AUTH_URL`, `PUBLIC_API_URL` and `PUBLIC_SITE_URL`, `strictPort` in all three dev configs, and the wrangler `.env.local` precedence over `.env`.

Rejected alternatives, one line each:

- Slots from a state file: zero collisions, but the ports change after a reset, and a state file can drift from the worktrees.
- Caddy with a hostname per worktree: isolates cookies with no code change, but the owner rejected the extra proxy and the domain setup.
- A fixed `ssh -L` for the whole range: 10,000 sockets on the laptop, and macOS allows 256 open files for each process by default.

### Phase 1: `wtports` on the box (#6)

- Add `config/bin/wtports`.
- `wtports` (no arguments) in a linked worktree: read `.devports.json`, compute the ports, apply the collision rule, write the marked block into each listed `.env.local`, then print one URL for each service.
- `wtports list`: print a table of repo, worktree, branch, service and port for every worktree under `~/projects` that has a `.devports.json`. Mark the ports that have a listener now.
- `wtports clean`: remove the marked block from each `.env.local` in the current worktree.
- Template placeholders: `{<service>}` for a service's port, and `{slug}` for a short worktree ID (the first 6 hex characters of `sha256("<repo>:<branch>")`).
- In the main checkout, print "the main checkout keeps its default ports" and exit with status 1.
- Add a `wtports` row to `docs/wiki/reference.md`.

Done when: in a scratch repo with a `.devports.json` and two linked worktrees, `wtports` writes a different block into each worktree's `.env.local`, a second run prints "no change", a forced collision gives the second worktree hash+1 with the comment, `wtports clean` removes only the block, and `wtports list` shows both worktrees with their ports.

### Phase 2: `wtforward` on the laptop (#7)

- Add `scripts/wtforward`. It takes the SSH host as an optional argument (default `devaloy`).
- Start: open the master with `ssh -M -S <socket> -fN <host>`.
- Loop: read `ss -ltnH` through the master, take the listeners in 10000 to 19999 plus `WTFORWARD_EXTRA`, then add the new forwards with `ssh -O forward` and remove the gone ones with `ssh -O cancel`. Print one line for each change.
- A port that is already in use on the laptop: print a warning once and skip it.
- `Ctrl+C`: close the master and remove the socket.
- Add a wiki page, `docs/wiki/run-worktrees-in-parallel.md`, with the laptop install step, the `wtports` flow, the restart note and the cookie note. Link it from `docs/wiki/index.md`.

Done when: `sh -n scripts/wtforward` and `shellcheck scripts/wtforward` pass, and the QA plan lists this manual laptop step: with `wtforward` running, `python3 -m http.server 12345 --bind 127.0.0.1` started on the box opens at `http://localhost:12345` on the laptop within 4 seconds, and the forward goes away within 4 seconds after the server stops.

### Phase 3: parallel QA session (#8)

Attended: the owner's QA session from the laptop browser. It needs Phases 1 and 2, and the primeshopr adoption issue, merged first.

- Run the main checkout and 3 linked worktrees of primeshopr at the same time, with `wtforward` on the laptop.
- Log in to admin in each one.

Done when: the target holds. All 4 checkouts serve web and admin on the laptop, each admin login stays active after you log in to the other three, and `wtports list` shows 9 hashed ports with no collision (3 worktrees with 3 services each; the main checkout uses its defaults).

## primeshopr adoption (brainaloylabs/primeshopr#146)

This work is filed as its own issue in the primeshopr repo. The file list:

- `apps/web/astro.config.mjs`, `apps/admin/vite.config.ts` and `apps/api/vite.config.ts`: read `DEV_PORT` from the app's own env files with Vite's `loadEnv`, and fall back to 3000, 3001 and 4000. Keep `strictPort`.
- `packages/auth/src/auth.ts` and `packages/auth/src/paths.ts`: read an optional `AUTH_COOKIE_PREFIX` and put it in front of `client` and `admin`. Accept it only when `BETTER_AUTH_URL` names a loopback host (the existing `isLocalDevUrl` check), so production keeps `client` and `admin`. Add the key to `packages/env/.env.example` as blank on purpose.
- Add `.devports.json` with the services `web` (3000), `admin` (3001) and `api` (4000), and these blocks:
  - `apps/web/.env.local`: `DEV_PORT={web}`, `PUBLIC_API_URL=http://localhost:{api}`, `PUBLIC_SITE_URL=http://localhost:{web}`
  - `apps/admin/.env.local`: `DEV_PORT={admin}`, `PUBLIC_API_URL=http://localhost:{api}`, `PUBLIC_SITE_URL=http://localhost:{web}`
  - `apps/api/.env.local`: `DEV_PORT={api}`, `BETTER_AUTH_URL=http://localhost:{api}`, `CORS_ORIGINS=http://localhost:{web},http://localhost:{admin}`, `AUTH_COOKIE_PREFIX=wt{slug}`
- Update the comments in the three configs and beside `DEV_ORIGINS` that say the ports cannot change.
- Add one line to the `## Worktree setup` section of `AGENTS.md`: run `wtports` by hand before `pnpm dev` to get this worktree's ports.

Done when (in primeshopr): in one linked worktree, `wtports && pnpm dev` starts all three apps on their hashed ports, an admin login from the laptop succeeds with no CORS error in the browser console, and `pnpm check` passes with `AUTH_COOKIE_PREFIX` unset.

## Open questions

None. Grilled on 2026-11-01. Q1 to Q3, Q13 and Q14 were asked. Q4 to Q12 were defaults that the owner kept.

## Non-goals

- No hostname routing, no TLS, no Tailscale Services.
- `wtports` does not start, stop or supervise dev servers, and no gitkit hook runs it.
- No change to the main checkout's ports in any project.
- No database isolation. Each primeshopr worktree already has its own `DATABASE_URL` from `pnpm db:setup`.
- Projects other than primeshopr adopt `.devports.json` in their own later work.
- Phone access. The phone has no SSH forward, so this plan serves the laptop only.

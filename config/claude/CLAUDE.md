## Where you are

You are running on **devaloy**, a headless remote devbox. It is an
`ubuntu:24.04` container reached only over Tailscale SSH — no public IP, no
published ports, no browser. Nobody is watching a GUI here, so anything that
wants to open a browser window, print a QR code, or wait on a localhost
callback will hang rather than fail.

## What persists and what does not

`/home/dev` is a Docker named volume. Cloned repos, shell history, and tool
credentials survive a redeploy. **Everything outside `/home/dev` is thrown away
on the next `docker compose up --build`** — including anything you `sudo
apt install`. If a tool is worth having, it belongs in the devaloy repo's
`Dockerfile`, not in an ad hoc install on the box.

There is no backup job and no snapshot. **Pushing to a remote is the only
backup.** Treat unpushed work on this box as work that can be lost.

## Committing

Never commit on your own. Leave changes uncommitted for the owner to review,
unless the prompt explicitly asks you to commit.

The exception is `afkkit`, whose whole purpose is to run an issue to a pull
request unattended — committing and pushing is the job, not a violation of it.

## Deleting

A shared guard (`~/.local/bin/rm-guard`, policy tier: Balanced) checks every
delete you run through Bash, so do not pre-emptively refuse a safe one or hand
the owner a manual to-do list. Just run the `rm`.

- **Safe, no prompt:** temp files, and git-*tracked* files inside a repo, which
  git can recover.
- **Risky, the owner is prompted:** untracked files, any `rm -rf` of a
  directory, globs, `..` traversal, `sudo`/`xargs` deletes, `git clean`, and
  anything outside a repo. Issue the command anyway — the prompt is the point.
- **Blocked outright:** `/`, `/home`, `/home/dev`, and system roots.

If a delete is denied, surface it to the owner rather than retrying it a
different way. And remember what this box does *not* have: no backup job, no
snapshot, and a home volume that a `docker compose down -v` erases entirely.
Git-tracked is only recoverable if it has been **pushed**.

## Background processes

Stop anything you started before ending a turn — dev servers, test watchers,
`pnpm dev`, a `--inspect` node. There is no desktop here to notice a stray
process and no Stop hook cleaning up after you, and a background job outlives
your SSH session: it keeps holding its port until someone logs in and kills it.

## Skills

Agent skills come from the `mimukit/skills` repo via the skills.sh CLI, not from
this box's config. `skmi` installs or refreshes them all; `skup` only updates
what is already installed, so a newly published skill needs `skmi`.

Three are installed but **cannot work here**, and invoking them wastes a turn:
`verifykit` (drives a real browser — there is none), `orcakit` and `orca-cli`
(both need the Orca desktop app on a Mac).

## The toolchain

Node, pnpm, gh, turbo and herdr come from `mise` and resolve through shims in
`~/.local/share/mise/shims`. To add or upgrade one, edit
`bootstrap-toolchain.sh` in the devaloy repo and run `devaloy-update` — do not
install a second copy with `apt` or a raw `curl | sh`.

After any `npm i -g`, run `devaloy-update` so the new binary is visible to
non-interactive sessions (`ssh devbox '<cmd>'`, `scp`, `rsync`, git-over-ssh).

## GitHub

If `GITHUB_TOKEN` is set in the environment, `gh` and `git push` over HTTPS are
already authenticated. Do not run `gh auth login` — it will refuse while that
variable is set, which is expected, not a fault to work around.

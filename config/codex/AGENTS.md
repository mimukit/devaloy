## Where you are

You are running on **devaloy**, a headless remote devbox — an `ubuntu:24.04`
container reached only over Tailscale SSH. No public IP, no published ports, no
browser, nobody watching a screen. Anything that wants to open a browser, print
a QR code, or wait on a localhost callback will hang rather than fail.

## What persists and what does not

`/home/dev` is a Docker named volume: repos, shell history and credentials
survive a redeploy. **Everything outside it is discarded on the next
`docker compose up --build`**, including anything installed with `sudo apt
install`. A tool worth keeping belongs in the devaloy repo's `Dockerfile`.

There is no backup. **Pushing to a remote is the only backup.** Unpushed work
on this box is work that can be lost.

## Committing

Never commit on your own. Leave changes uncommitted for the owner to review,
unless the prompt explicitly asks you to commit.

The exception is `afkkit`, whose whole purpose is to run an issue to a pull
request unattended — committing and pushing is the job, not a violation of it.

## Deleting

A shared guard (`~/.local/bin/rm-guard`) checks every delete you run, so do not
pre-emptively refuse a safe one — just run the `rm`. Temp files and git-tracked
files pass; untracked files, `rm -rf` of a directory, globs and `git clean`
prompt the owner; `/`, `/home`, `/home/dev` and system roots are blocked. If a
delete is denied, surface it rather than retrying it another way.

Note what recoverable means here: no backup job, no snapshot, and git-tracked
only helps if the work has been **pushed**.

## Background processes

Stop anything you started before ending a turn — dev servers, test watchers, a
stray `pnpm dev`. Nothing cleans up after you here, and a background job
outlives your SSH session while still holding its port.

## Skills

Agent skills come from the `mimukit/skills` repo via the skills.sh CLI, not from
this box's config. `skmi` installs or refreshes them all; `skup` only updates
what is already installed, so a newly published skill needs `skmi`.

Three are installed but **cannot work here**: `verifykit` (needs a real
browser), `orcakit` and `orca-cli` (need the Orca desktop app on a Mac).

## The toolchain

Node, pnpm, gh, turbo and herdr come from `mise` and resolve through shims in
`~/.local/share/mise/shims`. Add or upgrade one by editing
`bootstrap-toolchain.sh` in the devaloy repo and running `devaloy-update` —
not with `apt` or a raw `curl | sh`. Run `devaloy-update` after any `npm i -g`
so the binary is visible to non-interactive sessions.

## GitHub

If `GITHUB_TOKEN` is set, `gh` and `git push` over HTTPS are already
authenticated. Do not run `gh auth login`; it refuses while that variable is
set, and that is expected.

## Where you are

You are running on **devaloy**, a headless remote dev box — an `ubuntu:24.04`
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

**Nothing checks your deletes here.** The `rm-guard` hook that used to run on
every Bash call was removed on purpose — this is a throwaway container meant to
run unattended, and prompting on every `rm` defeated that. So: delete temp
files, build output and git-tracked files freely; read the target first (`ls`,
`git status`) before an `rm -rf`, a glob, or anything untracked; and never touch
`/`, `/home`, `/home/dev`, `~/.codex`, `~/.devaloy_secrets` or system roots.

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

Some are installed but **cannot work here**: `verifykit` (needs a real browser)
and `orcakit` (needs the Orca desktop app on a Mac).

`orca-cli` depends on how this box was built — it drives an Orca runtime, which
this box has only when built with `WITH_ORCA=true`. Check rather than assume:

```sh
command -v orca-ide && pgrep -f "orca-ide.*serve" >/dev/null && echo "runtime up"
```

If that prints nothing, `orca-cli` is inert here. Say so rather than trying to
start a runtime — that needs an image rebuild you cannot do from inside.

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

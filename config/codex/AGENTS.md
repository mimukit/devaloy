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

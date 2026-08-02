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

## Deleting

Deleting a git-tracked file is recoverable and fine. Deleting untracked files,
anything under `/home/dev` that is not inside a repo, or anything matching a
glob you have not listed first is not — surface it to the owner instead.

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

# Update the toolchain

Every tool on the box — node, pnpm, gh, turbo, lazygit, herdr, claude, codex, command-code, the skills CLI — is installed by `bootstrap-toolchain.sh` through mise, into the home volume. Which command updates it depends on what kind of change you are making, and picking the wrong one is how a tool ends up half-installed: visible in your shell but missing from `ssh devaloy '<cmd>'`, or upgraded on your laptop's copy of the repo but never on the box.

| You want to | Run |
|---|---|
| Upgrade the tools that track `latest` | `devaloy update` on the box (aliased to `update`) |
| Pick up a skill you just published to `mimukit/skills` | `skmi` on the box, or `devaloy update` |
| Add or remove a tool, or change a pin | Edit `bootstrap-toolchain.sh` in the repo, bump `TOOLSET_REVISION`, redeploy with `--build` |
| Make an `npm i -g` install visible everywhere | `devaloy update` after the install |

## Upgrade what tracks `latest`

Most of the toolchain is pinned to `latest`: pnpm, gh, turbo, lazygit, herdr, claude, codex, command-code, skills, and Paseo when `WITH_PASEO=true`. But `latest` does not move on its own. The boot path runs `mise install`, which resolves `latest` against what is already on disk and stops — that is deliberate, so a redeploy never swaps an agent CLI under a live session. The command that actually re-resolves is `mise upgrade`, and `devaloy update` is what runs it:

```sh
devaloy update
```

It runs `bootstrap-toolchain.sh --force` (which skips the revision gate and runs `mise upgrade`), then refreshes the `/usr/local/bin` shim mirror with `link-shims`. Run it as the dev user; it refuses to run as root.

Because it can move `claude` and `codex`, run it between agent sessions, not under one.

## Publish a skill to the box

Skills come from the `mimukit/skills` repo, not from `config/`. The publish loop is: push the skill, then on the box run either

```sh
skmi              # skills add mimukit/skills --global --skill '*' … — the skills half alone
devaloy update    # the same install, plus the full toolchain refresh
```

`skup` (`skills update`) is not enough: it only refreshes skills that are already installed, so it never notices a newly authored one. Only `skills add` — which both commands above run — does.

## Add a tool, remove one, or change a pin

The tool list lives in one place: the `mise use` lines in `bootstrap-toolchain.sh`. To change it:

1. Edit `bootstrap-toolchain.sh` in the repo. Add, remove, or pin the `mise use -g <tool>` line. Node's major is `MISE_NODE_VERSION` (default `24`); herdr's pin is `MISE_HERDR_VERSION`; both can also be set in `.env`.
2. Bump `TOOLSET_REVISION` at the top of the file whenever the tool *list* changes. The home volume records the revision it installed, and the boot path re-runs the bootstrap only when the two disagree — without the bump, every already-provisioned volume skips the script and the new tool never arrives. Leave the number alone for edits that do not add or remove a tool.
3. Redeploy **with a rebuild**. The script is baked into the image (`COPY … /usr/local/bin/` in the Dockerfile), so `docker compose up -d` alone still runs the old copy:

```sh
docker compose up -d --build
```

On the next boot the marker disagrees with the new revision and the bootstrap re-runs. That is close to free: the boot path installs, never upgrades, so every tool already on the volume stays where it is.

## After `npm i -g`

A global npm install lands in mise's node directory and works in your interactive shell, because the shims are on `PATH` there. Non-interactive sessions — `ssh devaloy '<cmd>'`, `scp`, `rsync`, git-over-ssh — resolve through the `/usr/local/bin` mirror instead, and the new binary is not in it yet. `devaloy update` refreshes the mirror; if you want only that half, the underlying command is:

```sh
sudo DEV_HOME="$HOME" link-shims
```

## What survives what

The whole toolchain lives in the home volume, so an ordinary redeploy keeps every tool and every version exactly as it was — including agents you upgraded with `devaloy update`. `docker compose down -v` destroys it along with everything else in `/home/dev`. The per-command details of `devaloy update`, `bootstrap-toolchain.sh`, and `link-shims` are in the [reference](reference.md).

_Verified against `main`@`a1f2d83` on 2026-08-25._

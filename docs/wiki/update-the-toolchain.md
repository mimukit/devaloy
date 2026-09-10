# Update the toolchain

Every tool on the box — node, pnpm, gh, turbo, lazygit, herdr, claude, codex, command-code, the skills CLI — is installed by `bootstrap-toolchain.sh` through mise, into the home volume. Which command updates it depends on what kind of change you are making, and picking the wrong one is how a tool ends up half-installed: visible in your shell but missing from `ssh devaloy '<cmd>'`, or upgraded on your laptop's copy of the repo but never on the box.

| You want to | Run |
|---|---|
| Upgrade the tools that track `latest` | `devaloy update` on the box (aliased to `update`) |
| Pick up a skill you just published to `mimukit/skills` | `skmi` on the box, or `devaloy update` |
| Add or remove a tool, or change a pin | Edit `config/mise/config.toml` in the repo, redeploy with `--build` |
| Make an `npm i -g` install visible everywhere | `devaloy update` after the install |

## Upgrade what tracks `latest`

Most of the toolchain is pinned to `latest`: pnpm, gh, turbo, lazygit, herdr, claude, codex, command-code, skills, and Paseo when `WITH_PASEO=true`. But `latest` does not move on its own. The boot path runs `mise install`, which resolves `latest` against what is already on disk and stops — that is deliberate, so a redeploy never swaps an agent CLI under a live session. The command that actually re-resolves is `mise upgrade`, and `devaloy update` is what runs it:

```sh
devaloy update
```

It runs `bootstrap-toolchain.sh --force` (which skips the toolset gate and runs `mise upgrade`), then refreshes the `/usr/local/bin` shim mirror with `link-shims`. Run it as the dev user; it refuses to run as root.

It finishes with `mise prune`, which deletes every installed version no tracked config asks for any more. `mise upgrade` installs the new version beside the old one and never removes the old directory, so without the prune the home volume keeps a copy of every claude, codex and pnpm you have ever run. A failed prune only warns: it costs disk, not a working toolchain. To see what would go before you run it, use `mise ls --prunable` or `mise prune --dry-run`.

Because it can move `claude` and `codex`, run it between agent sessions, not under one.

## Publish a skill to the box

Skills come from the `mimukit/skills` repo, not from `config/`. The publish loop is: push the skill, then on the box run either

```sh
skmi              # skills add mimukit/skills --global --skill '*' … — the skills half alone
devaloy update    # the same install, plus the full toolchain refresh
```

`skup` (`skills update`) is not enough: it only refreshes skills that are already installed, so it never notices a newly authored one. Only `skills add` — which both commands above run — does.

## Add a tool, remove one, or change a pin

The tool list lives in one place: `config/mise/config.toml`, a plain mise global config. `bootstrap-toolchain.sh` copies it to `~/.config/mise/config.toml` and runs `mise install`, so the script itself needs no edit. To change the list:

1. Edit `config/mise/config.toml` in the repo. Add, remove, or re-pin a line under `[tools]`. Use mise's own naming: a registry entry is bare (`lazygit = "latest"`), an npm package is prefixed (`"npm:turbo" = "latest"`). Node's major is also settable as `MISE_NODE_VERSION` in `.env` (default `24`), and herdr's pin as `MISE_HERDR_VERSION`; the bootstrap writes either into the seeded copy.
2. Nothing to bump. The bootstrap hashes the config it is about to install, plus the optional fragments the `WITH_*` keys turn on, and compares that against the marker in the home volume. Any edit to the file moves the hash, so an already-provisioned box re-runs on its next boot. The `TOOLSET_REVISION` constant this replaced had to be bumped by hand, and forgetting it left provisioned boxes skipping the bootstrap forever.
3. Redeploy **with a rebuild**. The config is baked into the image (`COPY config /opt/devaloy/config` in the Dockerfile), so `docker compose up -d` alone still installs the old list:

```sh
docker compose up -d --build
```

On the next boot the marker disagrees with the hash of the new config and the bootstrap re-runs. That is close to free: the boot path installs, never upgrades, so every tool already on the volume stays where it is.

## After `npm i -g`

A global npm install lands in mise's node directory and works in your interactive shell, because the shims are on `PATH` there. Non-interactive sessions — `ssh devaloy '<cmd>'`, `scp`, `rsync`, git-over-ssh — resolve through the `/usr/local/bin` mirror instead, and the new binary is not in it yet. `devaloy update` refreshes the mirror; if you want only that half, the underlying command is:

```sh
sudo DEV_HOME="$HOME" link-shims
```

## What survives what

The whole toolchain lives in the home volume, so an ordinary redeploy keeps every tool and every version exactly as it was — including agents you upgraded with `devaloy update`. `docker compose down -v` destroys it along with everything else in `/home/dev`. The per-command details of `devaloy update`, `bootstrap-toolchain.sh`, and `link-shims` are in the [reference](reference.md).

_Verified against `main`@`a1f2d83` on 2026-08-25._

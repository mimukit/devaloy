# Manage the fleet with `devaloy fleet`

`devaloy fleet` runs the `devaloy` verbs on every devaloy box on your tailnet, from any one of them. It lists the boxes, shows the status and doctor report of all of them at once, and updates them one at a time.

## Name every box `devaloy-<something>`

There is no list of boxes to keep. `devaloy fleet` asks Tailscale on each run and takes every Linux node whose Tailscale machine name starts with `devaloy-`, such as `devaloy-ovh` or `devaloy-insta`. Set the name with `TS_HOSTNAME` in `.env` for a container, or answer the installer's hostname question on a VM. A new box joins the fleet the first time it comes online, and a deleted node leaves it.

It reads the machine name, the first part of the MagicDNS name, not the OS hostname. Inside a container the OS hostname is the container's own name, so `devaloy-ovh` can show `devaloy` there. A Mac or a phone with a `devaloy-` name is left out, because only Linux nodes count.

The repo is public, so nothing about your boxes is written into it. Each run reads the addresses from `tailscale status --json` and connects with `ssh dev@<address>`. Tailscale SSH does the login, so there is no key to copy around.

## The commands

| Command | What it does |
|---|---|
| `devaloy fleet` or `devaloy fleet list` | One row per box: name, `online` or `offline`, runtime (`container` or `native`), and the clone of `~/projects/devaloy` as branch and short commit. A `*` after the commit means uncommitted changes. |
| `devaloy fleet status` | Runs `devaloy status` on every online box at the same time. Prints each box's output as one block, every line prefixed `<box>:`, then one `ok` or `failed (exit N)` line per box. |
| `devaloy fleet doctor` | The same for `devaloy doctor`. Exits `1` when any box fails. |
| `devaloy fleet update [box...]` | Updates the named boxes, or every online box. One box at a time, the box you run it on last. Stops at the first failed step. |

Offline boxes appear in `list` and are skipped by the other commands. An online box that SSH cannot reach shows `unreachable` in `list` and `failed (exit 255)` in `status`.

From your laptop, run it through any box:

```sh
ssh devaloy-ovh devaloy fleet status
```

## What `fleet update` does to each box

Each box gets three steps, and the run stops at the first one that fails:

1. **The clone gate.** In a container, `devaloy update` installs the CLI and config from `~/projects/devaloy`, so that clone is what the box runs. The gate requires the clone to be on `main`, to have no uncommitted changes, and to have no commits that `origin/main` lacks. Then it fast-forwards `main` to `origin/main`. A box with no clone passes and updates from the copy in `/opt/devaloy`.
2. **`devaloy update`**, the same as running it on that box.
3. **`devaloy health`**, which must exit `0`.

When the gate stops a box, its message names the fix: switch the clone to `main`, commit or remove the changes, or `git push` the commits that exist only on that box. The gate never changes a dirty clone or a feature branch, because it can hold work in progress.

The box you run `fleet update` on goes last because its update can replace the CLI, and the Claude Code or Codex binary of a session running there. Start a new agent session after it.

A name that is not a `devaloy-*` box, or a box that is offline, is refused before any box changes.

## Keep notes outside the repo

Copy the example notes file and fill in your boxes:

```sh
mkdir -p ~/.config/devaloy
cp ~/projects/devaloy/config/devaloy/fleet.example.md ~/.config/devaloy/fleet.md
```

`devaloy fleet` does not read it. The `devaloy-fleet` agent skill does, before it changes a box. Write what Tailscale cannot tell an agent: the provider, the role, and when a box must not update. The file lives on the home volume, so it survives a redeploy, and it never enters git.

## Let an agent run it

The `devaloy-fleet` skill comes with the box config, in `~/.claude/skills/devaloy-fleet/`. Ask Claude Code "check all my boxes" or "update the fleet". It runs `fleet list`, `fleet status` and `fleet doctor`, asks you before any update, updates one box at a time, and reports each result.

## See also

- [Manage the box with `devaloy`](manage-the-box.md): the verbs `fleet` runs on each box.
- [Update the toolchain](update-the-toolchain.md): what `devaloy update` changes.
- [Reference](reference.md#commands-on-the-box): every command in one table.

# Manage the box with `devaloy`

`devaloy` is one command for everything you do *to* the box rather than *on* it: check its disk and memory, reclaim both, update the toolchain, and find out what it was built with. Run it with no arguments and it opens a picker.

```sh
devaloy
```

The five older commands still work. `devaloy-update`, `devaloy-disk`, `devaloy-ram`, `devaloy-prune` and `devaloy-nvim-sync` are symlinks to `devaloy`, and it reads its own name to pick the verb. Anything a wiki page or a habit still types keeps working.

## The picker

It opens on a status screen: disk on the home volume, memory against the container's ceiling, swap, the Paseo daemon, Docker, and the toolset revision. Below a rule are the five things you can do.

| Key | What it does |
|---|---|
| `j` `k` | move down and up |
| `g` `G` | first row, last row |
| `l` or `enter` | open the view under the cursor |
| `h` or `esc` | back to the status screen |
| `a` | apply, on a view that has something to apply |
| `d` | the full report, on the terminal rather than in the list |
| `r` | re-read the figures, or re-run the scan |
| `q` | quit |

Keys are single letters rather than a search box, so `j` moves rather than typing a `j`. That needs fzf 0.65 or later. The picker checks the version it resolves and refuses to draw below it, naming `devaloy update` as the fix; every verb still runs from the command line on a box with an older fzf.

The figures refresh on `r` and when you come back from an action. There is no timer, because a `df` and a `find` every few seconds is a strange thing to run on the box whose resources you came here to conserve. Each reading carries the time it was taken.

## Reclaiming something

The three reclaim views work the same way. Opening one scans, and the scan writes down every file or process it intends to touch. The view shows the totals, `d` shows the whole list, and `a` asks you to type `yes` before anything happens.

**The apply consumes the list you just read.** It does not scan again. If a `pnpm install` lands between the report and the confirm, the new `node_modules` is not in the list and is not deleted. For the RAM reclaim the same contract needs one more step, because Linux reuses process IDs: the scan records each process's start time and the apply re-checks it, so a PID that was recycled in between is skipped and reported rather than killed.

From the command line the flags are unchanged:

```sh
devaloy disk                      # dry run, always read this first
devaloy disk --apply --docker     # node_modules, mise versions, logs, Docker
devaloy disk --apply --caches     # also the pnpm/npm/turbo caches
devaloy ram                       # report: what is holding the memory
devaloy ram --apply               # restart Paseo, TERM orphaned language servers
devaloy prune --apply --all       # also images no container is running
```

`devaloy prune` is the one behaviour change. The old `devaloy-prune` pruned as soon as you ran it; it now reports first and needs `--apply`, so every verb answers to the same contract and the picker can show you the reclaim before it happens.

### Restarting Paseo kills your terminal

`devaloy ram --apply` restarts the Paseo daemon, and every pane the daemon owns dies with it, including an agent mid-turn. When you run it *from* a Paseo pane, the confirm says so before you type `yes`. It does not refuse: that is the terminal you are most likely sitting in, and the reclaim is usually why you came.

## `devaloy doctor`

One screen of what this box was built with and what is actually working: the Docker daemon, the Orca runtime, browser capture, the Paseo daemon, `GITHUB_TOKEN`, Tailscale, the mise shim mirror, fzf, and the `devaloy` modules themselves.

The exit code is the useful part for a script or an agent:

| Exit | Meaning |
|---|---|
| `0` | nothing built into this image is broken. A row marked `·` is off by design. |
| `1` | something the image *was* built with is not working. |

"Docker is not reachable" means opposite things on a box built without `WITH_DOCKER` and on one built with it, and the probe cannot tell them apart. So the build writes the flags it was given to `/opt/devaloy/build-flags`, and doctor reads that file before it judges. `WITH_PASEO` is not in the file on purpose, because it is a runtime variable that `docker compose up -d` can change without a rebuild; doctor takes that one from the environment and from whether the daemon is running.

An image built before the flags file existed reports "build flags unknown" and never fails on a missing capability, since there is no way to know what was asked for.

## Without a terminal

With no terminal and no verb, `devaloy` prints the status as plain text and exits `0`.

```sh
ssh devaloy 'devaloy'
```

That is the block to grep from a script or an agent, instead of running `df`, `docker info` and `pgrep` separately.

## Where it lives

`devaloy` is at `/usr/local/bin/devaloy`, and its nine modules are at `/usr/local/lib/devaloy/`. The module list is fixed in the script rather than globbed, so a partial install fails at start naming the file that did not arrive, instead of turning up later as a verb that does not exist.

To run it from a checkout without installing it, point `DEVALOY_LIB` at the repo's `lib/`:

```sh
DEVALOY_LIB=./lib ./devaloy status
```

## See also

- [Size the container resource limits](vm-resource-limits.md) — the ceilings the RAM view reports against.
- [Update the toolchain](update-the-toolchain.md) — what `devaloy update` re-resolves.
- [Run a project stack on devaloy](run-a-project-stack.md) — the Docker daemon the prune view reclaims from.

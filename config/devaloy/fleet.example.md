# devaloy fleet notes

Copy this file to `~/.config/devaloy/fleet.md` on the box you manage the fleet from, then replace the example boxes with your own. That copy stays outside the repo, on the home volume. Never commit it: this repo is public.

`devaloy fleet` does not read this file. The `devaloy-fleet` agent skill reads it before it changes a box. Write here what the tailnet cannot tell an agent. Leave out addresses, tailnet domains, keys and tokens.

## devaloy-example-a

- Provider: a VPS host, 8 GB RAM
- Runtime: container, deployed with Dokploy
- Role: main box, most worktrees run here
- Update: any time

## devaloy-example-b

- Provider: a second VPS host, 4 GB RAM
- Runtime: native
- Role: overflow box for long agent runs
- Update: not while an afkkit run is going; ask first

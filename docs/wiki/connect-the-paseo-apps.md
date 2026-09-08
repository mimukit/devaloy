# Connecting the Paseo apps to devaloy

This walks through running the [Paseo](https://paseo.sh) daemon on devaloy and
connecting the phone, desktop, browser and CLI clients to it over your tailnet.

devaloy's default story is a terminal: Tailscale SSH plus `herdr`. The Paseo
apps are a different shape, the same way the Orca apps are. They talk to a
**daemon** that owns agent processes, worktrees and terminals, so reaching them
from a phone means running one on the box.

This is **opt-in** and off by default. Everything the
[README](../../README.md) says about Tailscale, the home volume and the
toolchain still holds.

## Paseo or Orca?

Both give you a phone client for agents running on this box, and they can run
side by side on different ports. Where they differ:

| | Orca (`WITH_ORCA`) | Paseo (`WITH_PASEO`) |
|---|---|---|
| Switch type | build argument, needs `--build` | environment variable, plain `up -d` |
| Image cost | 683 MB to 1.6 GB | none, it installs into the home volume |
| Upgrades | bump `ORCA_VERSION`, rebuild | `devaloy update`, like every other tool |
| Port and bind | 6768 on `0.0.0.0`, so the Docker host reaches it | 6767 on the tailnet address only |
| Connecting | pairing URL from the container log | direct connection you type into the app |

## 1. Turn it on

`WITH_PASEO` is an **environment variable**, so it changes what runs rather than
what is in the image:

```sh
# in .env, next to TS_AUTHKEY
WITH_PASEO=true
```

```sh
docker compose up -d
```

**No `--build`.** This is the opposite of `WITH_ORCA`, and it is the one thing
worth remembering from this page. Paseo is a plain npm package, so
`bootstrap-toolchain.sh` installs it into the home volume and nothing enters the
image.

The first boot after you flip the key re-runs the toolchain bootstrap. The
revision marker records the key alongside the revision, so a volume that already
finished revision 5 still notices that it now wants `5+paseo`. That re-run is
quick: the boot path installs and never upgrades, so `claude`, `codex` and
`herdr` stay exactly where they were.

## 2. Find the address

The daemon starts after the tailnet comes up, because it binds the tailnet
address:

```sh
docker compose logs devaloy | grep -i "Paseo daemon on"
```

```
[entrypoint] Paseo daemon on 100.x.y.z:6767 — add it in the app under
```

If instead you see `WARNING: no tailnet IPv4 — not starting the Paseo daemon`,
the tailnet did not come up and the daemon was deliberately skipped. Fix that
first; there is no point binding an address nothing can route to. See
[README → Recovering a box you can't reach](../../README.md#recovering-a-box-you-cant-reach).

If you see `WARNING: WITH_PASEO is true but paseo is not installed`, the
toolchain bootstrap did not finish. SSH in and run `devaloy update`.

## 3. Connect the phone or desktop app

Connect the Tailscale app on the phone first. The relay is deliberately disabled
on this box, so the tailnet is the only route and the app will simply fail to
connect without it.

Then in Paseo:

1. **Settings → Add host → Direct connection**
2. **Host**: the address from step 2, for example `100.x.y.z`
3. **Port**: `6767`
4. Leave **Use SSL** off
5. **Connect**

If you set `PASEO_PASSWORD`, enter it on the same screen.

## 4. Connect the CLI

On the box, plain `paseo` already talks to its own daemon:

```sh
paseo ls
paseo run "fix the failing tests"
```

No `--host` is needed because the boot writes the tailnet address into
`~/.paseo/config.json`, which is where the CLI looks. See
[Where the settings live](#where-the-settings-live).

From another machine on the tailnet, point it at the address:

```sh
paseo --host 100.x.y.z:6767 ls
```

## 5. The browser client, if you want it

A second key serves Paseo's bundled web app from the daemon's own origin, so any
browser on the tailnet is a full client with nothing to install:

```sh
# in .env
WITH_PASEO_WEB_UI=true
PASEO_PASSWORD=something-long-and-random
```

Then open `http://100.x.y.z:6767/`.

The password is optional but strongly wanted here. The static UI files load
without authentication, so with no password anything that reaches the tailnet
address gets a browser client and an open API. The entrypoint warns about it in
the container log and serves the UI anyway, on the reasoning that the API on
that address is open either way, so withholding just the UI would cost you a
working surface and protect nothing.

Two things to know about the password:

- It is **daemon-wide**, not web-UI only. Setting it means the phone's direct
  connection asks for it too.
- The daemon reaches it through `~/.devaloy_secrets`, which is rebuilt from
  scratch on every boot, so clearing it in `.env` and redeploying really does
  revoke it.

`daemon.hostnames` is set for you from `TS_HOSTNAME`, plus `.ts.net`, which is
what lets a MagicDNS name work in the browser. Paseo allows `localhost`,
`*.localhost` and every IP address before it looks at that list, and answers
`403 Host not allowed` to any other name. The list only adds to the defaults, so
it never costs you the connection to a bare IP — and because the same check
gates the WebSocket upgrade, devaloy sets it whether or not the web UI is on.

## 6. Confirm it survives a redeploy

Paseo keeps its state under `~/.paseo`, which lives in the `home` volume:

```sh
docker compose down && docker compose up -d
```

Your clients should reconnect with nothing to reconfigure.

## Where the settings live

`~/.paseo/config.json` holds the daemon's settings, and it is not only the
daemon's file. Every `paseo` on the box reads it to find the daemon — `paseo
ls`, `paseo daemon restart`, the MCP endpoint — and Paseo's own default is
`127.0.0.1:6767`, which is not where this daemon listens. That is why devaloy
writes the address into the file instead of passing it on the command line: a
restart you run yourself over SSH then behaves the same as the one the boot
does.

The entrypoint rebuilds the file on every boot, from three layers. Each
overrides the one before it:

| Layer | Where it comes from | Example |
|---|---|---|
| 1 | the file already in the `home` volume | a setting you changed in the app under a key the repo does not ship |
| 2 | `config/paseo/config.json` in the repo | `daemon.agentProfiles`, `daemon.terminalProfiles`, `daemon.relay.enabled`, `daemon.cors.allowedOrigins`, `worktrees.root` |
| 3 | the container environment, at boot | `daemon.listen`, `daemon.hostnames`, `features.webUi.enabled` |

Objects merge key by key and arrays are replaced whole. So a key the repo does
not ship survives a redeploy, and a key it does ship is reset from the repo. If
you want a setting to hold, put it in `config/paseo/config.json` rather than
editing the file on the box.

## Agent profiles and terminal profiles

The repo ships both profile lists, so every deployment starts with the same
named agents and their icons instead of the app defaults:

| Profile | Provider | Model | Icon |
|---|---|---|---|
| manager | claude | `claude-opus-5` | rocket |
| thinker | claude | `claude-fable-5-1` | sparkles |
| worker | claude | `claude-sonnet-5` | hammer |
| thinker cx | codex | `gpt-6-astra` | sparkles |
| worker cx | codex | `gpt-5.6-luna` | hammer |

The terminal profiles are Claude Code, Codex and Lazygit.

Both lists are arrays, so the boot replaces them whole. A profile you add in
the app is gone after the next redeploy. Add it to
`config/paseo/config.json` instead, give it an `id` no other profile uses, and
redeploy.

Workspaces, projects and their custom icons are not in this file. They live in
`~/.paseo/projects/`, the daemon owns them, and the `home` volume is what
carries them across a redeploy.

`PASEO_PASSWORD` is the exception and stays out of the file. `daemon.auth.password`
takes a bcrypt hash and nothing else, so the plaintext lives in
`~/.devaloy_secrets` and the daemon hashes it when it starts.

Check what the boot wrote:

```sh
docker compose logs devaloy | grep -i "Paseo config"
```

```
[entrypoint] Paseo config written to ~/.paseo/config.json (listen 100.x.y.z:6767)
```

A `WARNING: could not write ~/.paseo/config.json` line instead means the merge
failed. The daemon still comes up on the right address, from flags, but `paseo`
on the box then needs `--host 100.x.y.z:6767`.

## What this does not change

- **Nothing is published.** There is still no `ports:` key. The daemon binds the
  tailnet address inside the container's own network namespace, which is the
  same reason Tailscale SSH needs no published port. Unlike Orca's 6768, port
  6767 is *not* on the docker bridge and the Docker host cannot reach it.
- **Tailscale SSH stays the primary path.** Paseo is additive, and the container
  still lives or dies with `tailscaled`. If the daemon wedges, you can still SSH
  in.
- **The relay stays off.** Paseo can tunnel to your daemon through
  `app.paseo.sh`, end-to-end encrypted, which is how you would reach it from a
  phone with no VPN. devaloy ships `daemon.relay.enabled: false`, because an
  outbound tunnel is exactly what would make "the tailnet is the only remote way
  in" false.

## What does not work

**Workspace service previews.** Paseo can run a workspace's dev server and proxy
it, but it routes by hostname on the daemon port, at names like
`web-feature-x-myapp.localhost:6767`. Those names do not resolve from a phone on
the tailnet, and making them resolve needs wildcard DNS pointing at the tailnet
address, which MagicDNS does not do. This is a DNS limit rather than a Paseo
one. Agents, terminals, diffs and git all work normally.

## Gotchas

| Thing | Why it bites |
|---|---|
| Reaching for `--build` | `WITH_PASEO` is an environment variable. `--build` is harmless but does nothing, and expecting to need it means you will assume it behaves like `WITH_ORCA` in other ways too. |
| `WITH_PASEO=false` leaves `paseo` on `PATH` | The key stops the daemon. It does not uninstall the CLI or rewrite `~/.paseo/config.json`, so turning it back on costs nothing. A `paseo` with no daemon behind it does nothing. |
| Editing `~/.paseo/config.json` on the box | Only the keys the repo does not ship survive a redeploy. `daemon.listen`, `daemon.hostnames`, `features.webUi.enabled`, `daemon.relay.enabled`, `daemon.cors.allowedOrigins` and `worktrees.root` are all rewritten on the next boot. |
| No password by default | Anything on your tailnet can drive your agents. That is the same trust model Tailscale SSH already runs on here, but it surprises people who expected the app to ask for something. |
| A different tool list inside agents | Paseo injects its own orchestration tools into every agent it launches, so a Claude Code session started from the phone can spawn other agents. A session you started over SSH cannot. |
| Upgrading | `devaloy update`, not a rebuild. This is the opposite of Orca. Paseo always tracks `latest` and there is no variable to pin it. Do not add a `MISE_PASEO_VERSION`: mise reads any `MISE_<TOOL>_VERSION` as a request for a tool called `<TOOL>`, `paseo` is not in its registry, and setting one breaks every `mise` command on the box. Edit the pin in `bootstrap-toolchain.sh` instead. |
| A tailnet IP that changed | The daemon binds the address captured at boot, and `daemon.listen` in the config still holds the old one. If `tailscaled` ever re-registers on a different IPv4, restart the container and both are rewritten. The node identity lives in the `tailscale-state` volume, so this is rare. |
| Both runtimes at once | Fine. Orca is 6768, Paseo is 6767, and neither knows about the other. |

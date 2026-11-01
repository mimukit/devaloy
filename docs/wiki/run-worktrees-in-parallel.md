# Run worktrees in parallel

Most projects use fixed dev ports such as 3000, 3001 and 4000, so only one checkout of a project can run `pnpm dev` at a time. Two tools lift that limit. `wtports` runs on the box and gives each linked worktree its own ports, and `wtforward` runs on your laptop and makes every one of those ports open at `http://localhost:<port>`.

The main checkout keeps the project's default ports. Each linked worktree gets ports from 10000 to 19999, computed from a hash of the repo name, the service name and the branch, so a worktree gets the same ports every time.

## Why `localhost` and not `http://devaloy:<port>`

The apps build their API URLs and allowed CORS origins from `localhost`, never from the box's tailnet name, so the browser must reach them at `localhost` too. `wtforward` keeps one SSH connection to the box and adds an SSH port forward for each dev server it finds, with the same port number on both sides.

A forward connects to `127.0.0.1` on the box. A dev server must listen on `127.0.0.1` or `0.0.0.0` for the forward to reach it. A server that listens only on the tailnet address refuses the forwarded connection.

## 1. Install `wtforward` on the laptop

The script uses only POSIX `sh` and `ssh`, so it runs on macOS and Linux with nothing else installed. `ssh devaloy` must already work from the laptop, through Tailscale SSH.

```sh
mkdir -p ~/.local/bin
scp devaloy:projects/devaloy/scripts/wtforward ~/.local/bin/
chmod +x ~/.local/bin/wtforward
```

`~/.local/bin` must be on your `PATH`. Run the same `scp` again to update the script.

## 2. Give a worktree its ports with `wtports`

On the box, in a linked worktree of a project that has a `.devports.json` at its root, run `wtports` by hand before the project's own dev command:

```sh
cd ~/worktrees/myapp/issue-42-add-login
wtports
pnpm dev
```

`wtports` reads `.devports.json`, computes the ports, and writes them into each app's `.env.local` between a `# >>> wtports` line and a `# <<< wtports` line. It keeps every line outside that block. Then it prints one URL for each service. It does not start, stop or watch the dev servers.

| Command | What it does |
|---|---|
| `wtports` | Writes this worktree's block into each listed `.env.local` and prints the URLs. Prints `no change` when the block is already current. |
| `wtports list` | Prints the repo, worktree, branch, service and port of every worktree under `~/projects` that has a `.devports.json`, and marks the ports that have a listener now. |
| `wtports clean` | Removes the block from each `.env.local` in this worktree. |

In the main checkout, `wtports` prints "the main checkout keeps its default ports" and exits with status 1.

When the hashed port is taken by another worktree's block or by a running listener, `wtports` takes the next free port and says so in a comment in the block, for example `DEV_PORT=16461  # hash 16460 taken by issue-91`. Later runs keep the port from the block, so the worktree that ran first keeps its port.

## 3. Start `wtforward`

On the laptop, start it in a terminal and leave it open:

```sh
wtforward            # the box at the SSH host devaloy
wtforward mybox      # another SSH host
```

It prints one line for each forward it adds or removes:

```
connected to devaloy; checking its listeners every 2s
forward localhost:16460 -> devaloy:16460
forward localhost:3000 -> devaloy:3000
cancel localhost:16460 (devaloy:16460 stopped)
```

Open the URL that `wtports` printed. A new dev server opens on the laptop within one interval after it starts listening on the box.

| Variable | Default | Meaning |
|---|---|---|
| `WTFORWARD_INTERVAL` | `2` | Seconds between two reads of the box's listeners. |
| `WTFORWARD_EXTRA` | `3000 3001 3002 4000` | Ports outside 10000 to 19999 to forward too, for the main checkouts. |

Press `Ctrl+C` to stop it. It closes the SSH connection and removes its control socket, so every forward goes away with it.

When a port is already in use on the laptop, for example by a local dev server on 3000, `wtforward` prints one warning and skips that port. It forwards each port on `127.0.0.1` and on `::1` separately, so a laptop process on either address counts as in use. On a laptop with no IPv6 loopback, it prints one notice at the start and forwards on `127.0.0.1` only. It tries the port again after the box server on that port stops and starts again. To try at once, stop the laptop process and restart `wtforward`.

When the SSH connection drops, for example after the laptop sleeps, `wtforward` prints `the connection to devaloy closed` and exits. Start it again.

## Restart the dev server after `wtports` changes a port

A dev server reads `.env.local` when it starts. The Cloudflare Vite plugin watches only `.env` and `.dev.vars` for changes, so a change to `.env.local` takes effect only after a restart. When `wtports` changes a block, it says to restart `pnpm dev`. When it prints `no change`, the running server is already current.

## Cookies are shared across ports

Browsers do not isolate cookies by port, and this includes `localhost` (RFC 6265, section 8.5). Two worktrees of one app at `localhost:16460` and `localhost:17311` share every cookie name, so a login in one worktree replaces the session cookie of the other.

To keep the logins apart, `wtports` writes `AUTH_COOKIE_PREFIX=wt<slug>` into the block, where `<slug>` is a short ID for the worktree. A project that reads the key puts it in front of its cookie names, so each worktree gets its own session cookie. When the key is unset, as in the main checkout, the cookie names stay the project's defaults.

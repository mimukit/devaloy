# Connect the T3 Code apps to devaloy

This guide runs the [T3 Code](https://github.com/pingdotgg/t3code) server on devaloy and pairs two clients with it over your tailnet: the T3 Code desktop app on your laptop and the T3 Code phone app.

The server owns the agent threads, so they run on the box. Close the laptop and a Claude Code thread keeps going, and the phone can follow it. The setup is opt-in and off by default.

## T3 Code or Paseo?

Both give you a GUI client for agents on this box, and they can run side by side on different ports.

| | Paseo (`WITH_PASEO`) | T3 Code (`WITH_T3CODE`) |
|---|---|---|
| Switch type | environment variable, plain `up -d` | environment variable, plain `up -d` |
| Image cost | none, home volume | none, home volume |
| Upgrades | `devaloy update` | `devaloy update` |
| Port and bind | 6767 on the tailnet address | 3773 on the tailnet address |
| Connecting | direct connection typed into the app | one-time pairing link per device |
| Settings | `config/paseo/config.json`, merged each boot | the apps own them; devaloy writes none |

## 1. Turn it on

`WITH_T3CODE` is an environment variable, so a plain `up -d` picks it up.

1. Set the key in `.env`:

   ```sh
   WITH_T3CODE=true
   ```

2. Restart the container:

   ```sh
   docker compose up -d
   ```

The first boot after the change re-runs the toolchain bootstrap, which installs `npm:t3` from `config/mise/optional/t3code.toml`. The entrypoint then starts `t3 serve --host <tailnet-ip> --port 3773 --no-browser` in a restart loop.

Check that it started:

```sh
docker compose logs devaloy | grep "T3 Code server on"
```

## 2. Pair the laptop

The laptop needs Tailscale on, in the same tailnet as the box, and the T3 Code desktop app.

1. Find the pairing link in the container log:

   ```sh
   docker compose logs devaloy | grep -i -A3 "pairing"
   ```

   It looks like `http://100.x.y.z:3773/pair#token=...`.

2. In the desktop app, open **Settings → Connections → Add environment**.
3. Paste the link and connect.

To use the laptop only as a client of the box, turn off **Local environment** in **Settings → Connections**.

## 3. Pair the phone

The phone needs the Tailscale app connected to the same tailnet, and the T3 Code app from the store.

1. On the laptop, print a fresh link for the phone:

   ```sh
   ssh devaloy t3 pair
   ```

   It prints a link and a QR code. The link carries the tailnet address, not `127.0.0.1`.

2. In the phone app, open **Settings → Environments → Add environment**.
3. Scan the QR code.

Each link works once. Run `ssh devaloy t3 pair` again for each new device.

## 4. Turn on phone notifications

Pairing does not give the phone push notifications. The pairing link opens a live connection to the server, and that connection closes when the app goes to the background. The server sends agent state (needs input, finished, failed) to phones only through T3 Connect, the hosted relay of T3 Code. A box with no T3 Connect link sends nothing, and no log line says so.

The link needs your sign-in, so the boot cannot make it. You do it once. The link is stored in `~/.t3/userdata/secrets/` on the `home` volume, so a redeploy keeps it.

1. On the box, as `dev`, run:

   ```sh
   t3 connect link --publish-only --headless
   ```

   `--headless` prints a code and a URL for the sign-in, because the box has no browser. Open the URL on the laptop or the phone and sign in.

2. Restart the server, because the link takes effect on the next start. The restart cancels running turns.

   ```sh
   devaloy ram --t3 --apply
   ```

3. Check the link:

   ```sh
   t3 connect status
   ```

   `Environment link` shows `provisioned`, `Relay` shows a URL, and `Publish agent activity` shows `enabled`.

4. In the phone app, sign in to T3 Connect with the same account. The phone registers itself with the relay, and the relay sends a push to each registered device.
5. In the Android or iOS settings, allow notifications for the T3 Code app.
6. Start a turn from the phone, put the app in the background, and wait for the turn to finish. A notification arrives.

`--publish-only` links the box for push only. It starts no managed tunnel and installs no relay client, so the tailnet stays the only route to the server. Without the flag, `t3 connect link` also sets up a public tunnel, which this box does not need.

For each state change the relay receives the project title, the thread title, the model name, the state and a fixed headline such as `Agent finished`. The thread title is often written from your first prompt, so it can carry words from it. The server sends no prompt text and no replies.

To stop push, run `t3 connect publish --disable` and restart the server. `t3 connect publish` turns it on again.

`devaloy doctor` has a `t3 push` row for this link. It shows `ok` when the box is linked and publishes, and `off` when you never linked it. It shows `broken` when you ran the link but the server has not provisioned it, or when T3 Connect revoked it.

The [ntfy push](push-notifications.md) is a separate route. It sends to the ntfy app, not to the T3 Code app, and it needs no T3 Connect account.

## Open a thread on each new worktree

gitkit, issuekit `start`, and mergekit `start` end with a `Workspace ready` block when they hand you a worktree. The block names no tool. In T3 Code, a short instruction file tells Claude to open an idle thread bound to that worktree. You type the first prompt in that thread yourself.

The file is `config/claude/t3-workspaces.md` in this repo. The boot and `devaloy update` copy it to `~/.claude/t3-workspaces.md`. Claude Code does not load that file by itself, so it reaches only the sessions that T3 Code starts with the launch argument below.

1. On the box, run `devaloy update` so the file is in `~/.claude/`.
2. In the desktop app, open **Settings → Providers → Claude**.
3. Set **Launch arguments** to:

   ```
   --append-system-prompt-file /home/dev/.claude/t3-workspaces.md
   ```

4. Start a new thread. A thread that already runs reads the file only after its session restarts.
5. In a repo with a `ready` issue, run `issuekit start <n>`. Check that one idle thread opens on the worktree.
6. Run `issuekit start <n>` again. Check that the reply links the same thread and opens no second one.

Use an absolute path. T3 Code resolves a relative path against each thread's working directory, which changes from thread to thread.

The launch argument lives in T3 Code's own settings under `~/.t3/userdata`, not in this repo. If you reset those settings, set it again. This setup covers the Claude provider only, so Codex threads in T3 Code do not open these threads.

## How the connection works

The apps use plain HTTP to the tailnet address. That is safe here, because WireGuard encrypts every tailnet packet. The T3 Code phone app allows plain HTTP on purpose so that it can reach servers on a LAN or a tailnet.

`http://devaloy:3773`, the MagicDNS name, also reaches the server. Once connected, the apps learn the box's Tailscale addresses and keep them as routes.

There is no Tailscale Serve and no HTTPS. The hosted web app at `app.t3.codes` needs HTTPS, so it does not work with this setup. T3 Connect, the hosted relay, carries no connection to the server. With the publish-only link from [step 4](#4-turn-on-phone-notifications), the server only sends agent state out to it for push. The tailnet is the only route in.

If your tailnet policy has its own `acls` or `grants` instead of the default allow-all rule, add a rule that lets your laptop and phone reach port 3773 on the box.

## Revoke a device

- In the desktop app, open **Settings → Connections** and revoke the device's session.
- Or, on the box, run `t3 auth --help` and use the session commands it lists.

## What devaloy sets, and what it leaves to you

The supervisor sets two environment variables and nothing else:

| Variable | Value | Why |
|---|---|---|
| `T3CODE_TELEMETRY_ENABLED` | `false` | No analytics leave the box. |
| `T3CODE_SERVER_BROWSER_SANDBOX` | `0` | Chrome's own sandbox needs user namespaces that the container does not give it. The container is the isolation layer. |

Everything else is in `~/.t3/userdata/settings.json`, which the apps own. devaloy never writes it.

At boot, devaloy links `~/.t3/worktrees` to `~/worktrees`, the same root Paseo uses. If `~/.t3/worktrees` is already a real directory, the boot leaves it alone and logs one line. Both tools write into the same folder, so two worktrees with the same name collide.

All T3 Code state is in `~/.t3` on the `home` volume. A redeploy keeps it, and paired devices stay paired.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The app says the server is on a different version | The store app updated and the box did not | Redeploy the container, or run `devaloy update` on the box. Each boot upgrades `t3` before it starts the server. `devaloy update` upgrades it and then restarts a server left on the older version. Do not run `t3 update`. |
| The log says `WITH_T3CODE is true but t3 is not installed` | The toolchain bootstrap did not finish | Run `devaloy update`, then restart the container. |
| The log says `no tailnet IPv4 — not starting the T3 Code server` | Tailscale did not come up | Fix the Tailscale error above it in the log, then restart the container. |
| A turn stopped after `devaloy update`, `devaloy ram --t3 --apply` or a restart | A server restart cancels running turns | Threads and history are kept. Turn on "continue threads after a server update" in the app to resume interrupted turns. |
| A browser tab fails to open | The image has no Chrome libraries | Work without browser tabs; the server keeps running. A `WITH_BROWSER=true` build adds the Chromium libraries Playwright needs, which may also cover T3 Code's browser. This is not tested. |
| The phone cannot connect | Tailscale is off on the phone, or the tailnet policy blocks port 3773 | Connect Tailscale on the phone. Check the policy. |
| The phone app shows no notifications | The box has no T3 Connect link, or the server has not restarted since the link | Run `devaloy doctor` and read the `t3 push` row. Follow [step 4](#4-turn-on-phone-notifications). |
| `ssh devaloy t3 pair` finds no server | The server is down | Run `devaloy doctor`. Check the `t3 server` row. |

## Manage the server

- `devaloy status` shows the server and its memory.
- `devaloy doctor` shows a `t3 server` row, a `t3 cli` row and a `t3 push` row.
- `devaloy ram --t3` reports the server's memory. Add `--apply` to restart it. The restart cancels running turns. A plain `devaloy ram --apply` leaves the server alone.

## Turn it off

1. Set `WITH_T3CODE=false` in `.env`.
2. Run `docker compose up -d`. The server does not start.
3. Run `devaloy update` on the box. Its `mise prune` removes the `t3` CLI.

`~/.t3` stays on the home volume, so the paired devices work again when you turn the key back on.

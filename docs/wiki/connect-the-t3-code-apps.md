# Connect the T3 Code apps to devaloy

This guide runs the [T3 Code](https://github.com/pingdotgg/t3code) server on devaloy and pairs two clients with it over your tailnet: the T3 Code desktop app on your laptop and the T3 Code phone app.

The server owns the agent threads, so they run on the box. Close the laptop and a Claude Code thread keeps going, and the phone can follow it. The setup is opt-in and off by default.

## T3 Code, Paseo or Orca?

All three give you a GUI client for agents on this box, and they can run side by side on different ports.

| | Orca (`WITH_ORCA`) | Paseo (`WITH_PASEO`) | T3 Code (`WITH_T3CODE`) |
|---|---|---|---|
| Switch type | build argument, needs `--build` | environment variable, plain `up -d` | environment variable, plain `up -d` |
| Image cost | 683 MB to 1.6 GB | none, home volume | none, home volume |
| Upgrades | bump `ORCA_VERSION`, rebuild | `devaloy update` | `devaloy update` |
| Port and bind | 6768 on `0.0.0.0` | 6767 on the tailnet address | 3773 on the tailnet address |
| Connecting | pairing URL from the container log | direct connection typed into the app | one-time pairing link per device |
| Settings | none | `config/paseo/config.json`, merged each boot | the apps own them; devaloy writes none |

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

## How the connection works

The apps use plain HTTP to the tailnet address. That is safe here, because WireGuard encrypts every tailnet packet. The T3 Code phone app allows plain HTTP on purpose so that it can reach servers on a LAN or a tailnet.

`http://devaloy:3773`, the MagicDNS name, also reaches the server. Once connected, the apps learn the box's Tailscale addresses and keep them as routes.

There is no Tailscale Serve and no HTTPS. The hosted web app at `app.t3.codes` needs HTTPS, so it does not work with this setup. T3 Connect, the hosted relay, is not used either. The tailnet is the only route in.

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
| The app says the server is on a different version | The store app updated and the box did not | Run `devaloy update` on the box. Do not run `t3 update`. |
| The log says `WITH_T3CODE is true but t3 is not installed` | The toolchain bootstrap did not finish | Run `devaloy update`, then restart the container. |
| The log says `no tailnet IPv4 — not starting the T3 Code server` | Tailscale did not come up | Fix the Tailscale error above it in the log, then restart the container. |
| A turn stopped after `devaloy ram --t3 --apply` or a restart | A server restart cancels running turns | Threads and history are kept. Turn on "continue threads after a server update" in the app to resume interrupted turns. |
| A browser tab fails to open | The image has no Chrome libraries | Work without browser tabs; the server keeps running. A `WITH_BROWSER=true` build adds the Chromium libraries Playwright needs, which may also cover T3 Code's browser. This is not tested. |
| The phone cannot connect | Tailscale is off on the phone, or the tailnet policy blocks port 3773 | Connect Tailscale on the phone. Check the policy. |
| `ssh devaloy t3 pair` finds no server | The server is down | Run `devaloy doctor`. Check the `t3 server` row. |

## Manage the server

- `devaloy status` shows the server and its memory.
- `devaloy doctor` shows a `t3 server` row and a `t3 cli` row.
- `devaloy ram --t3` reports the server's memory. Add `--apply` to restart it. The restart cancels running turns. A plain `devaloy ram --apply` leaves the server alone.

## Turn it off

1. Set `WITH_T3CODE=false` in `.env`.
2. Run `docker compose up -d`. The server does not start.
3. Run `devaloy update` on the box. Its `mise prune` removes the `t3` CLI.

`~/.t3` stays on the home volume, so the paired devices work again when you turn the key back on.

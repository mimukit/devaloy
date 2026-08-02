# Pairing the Orca apps with devaloy

This walks through running the [Orca](https://www.onorca.dev/) runtime on
devaloy and pairing the desktop and mobile apps with it, over your tailnet.

devaloy's default story is a terminal: Tailscale SSH plus `herdr`, which is
everything a laptop or a phone with an SSH client needs. The Orca apps are a
different shape — they talk to a **runtime**, not a terminal — so reaching them
from a phone means running one on the box.

This is **opt-in**. A stock devaloy has no Orca in it, and turning it on roughly
triples the image. Everything the [README](../../README.md) says about
Tailscale, the home volume and the toolchain still holds.

## Why a runtime, not SSH targets

Orca can drive a remote machine over SSH from your desktop, and that mode needs
nothing new on the box — but the desktop has to stay awake to broker it, and
there is no path to the mobile app at all. A **Remote Orca Server** is the only
mode where the phone alone is a complete client and agents keep running after
your laptop sleeps. devaloy is already the always-on box, so that is the mode
worth having here.

## 1. Build it in

`WITH_ORCA` is a **build argument**, so it decides what goes into the image:

```sh
# in .env, next to TS_AUTHKEY
WITH_ORCA=true
```

```sh
docker compose up -d --build
```

**`--build` is load-bearing.** A plain `docker compose up -d` does not re-read
build arguments — it will start the old image and leave you wondering why the
log never mentions Orca. If you take one thing from this page, take that.

Expect the first build to be a few minutes longer: it pulls a ~154 MB package
and the Chromium runtime libraries underneath it.

## 2. Find the pairing URL

The server starts after the tailnet comes up — it needs the tailnet address to
advertise — and prints its pairing URL to the **container log**. That is a
non-obvious place to look for it, so look there first:

```sh
docker compose logs devaloy | grep -i pairing
```

You should also see the entrypoint's own line naming the address and port:

```
[entrypoint] Orca server on 100.x.y.z:6768 — pair a client with the URL
```

If instead you see `WARNING: no tailnet IPv4 — not starting orca serve`, the
tailnet did not come up and Orca was deliberately skipped. Fix that first —
there is no point advertising an address nothing can route to. See
[README → Recovering a box you can't reach](../../README.md#recovering-a-box-you-cant-reach).

## 3. Pair the desktop app

Open the URL from the log in the Orca desktop app. The app is the UI; the box
owns the projects, worktrees, terminals and agent processes.

Your desktop can now sleep without stopping anything running on devaloy.

## 4. Pair the phone

The mobile pairing code is a separate invocation rather than a flag on the
running server — it prints a mobile-scoped QR and link:

```sh
docker compose exec -u dev devaloy \
  xvfb-run -a orca-ide serve \
    --pairing-address "$(docker compose exec devaloy tailscale ip -4 | head -1)" \
    --mobile-pairing
```

Scan it with the Orca mobile app, with the Tailscale app connected on the phone.

## 5. Confirm it survives a redeploy

Paired devices are recorded under `~/.config`, which lives in the `home` volume,
so pairings are not tied to the container:

```sh
docker compose down && docker compose up -d
```

Both clients should reconnect without re-pairing. If they do **not**, the likely
cause is Electron's `safeStorage` falling back from libsecret because there is
no session bus on this box — the fix is adding `dbus-x11` and wrapping the
launch in `dbus-run-session`. It ships without that deliberately, on the
evidence that pairings survive.

## What this does not change

- **Nothing is published.** There is still no `ports:` key. `orca serve` binds
  6768 inside the container's own network namespace, which the tailnet address
  already reaches — the same reason Tailscale SSH needs no published port.
- **Tailscale SSH stays the primary path.** Orca is additive, and the container
  still lives or dies with `tailscaled`, not with Orca. If the runtime wedges,
  you can still SSH in.
- **The home volume still holds everything that matters.** Orca's state joins
  the repos and credentials already there.

## Gotchas

| Thing | Why it bites |
|---|---|
| `docker compose up -d` with no `--build` | Build args are not re-read. Nothing changes and there is no error. |
| Upgrading Orca | Pinned by `ARG ORCA_VERSION` in the `Dockerfile`. Bump it and rebuild — `devaloy-update` does **not** cover it, unlike every other tool here. |
| Stopping a misbehaving Orca | There is no runtime toggle. The entrypoint restarts it in an unbounded loop, so `pkill` will not stick — use `docker compose stop`, or `WITH_ORCA=false` and rebuild. |
| `[autoUpdater] Checking for update` in the log | Expected noise. It cannot apply anything (`/opt` is root-owned, the server runs as `dev`), but a check that downloads would land ~160 MB in the home volume. |
| `Failed to connect to the bus` in the log | Expected noise — there is no session bus here. Harmless unless pairings stop surviving a redeploy; see step 5. |
| Two devaloy boxes both built `WITH_ORCA=true` | Orca warns against two servers for the same setup. The default of `false` is most of the guard; nothing stops you opting in twice. |
| Port 6768 on the docker bridge | `orca serve` binds `0.0.0.0` and has no bind-address flag, so the port is reachable from the Docker host. Accepted — that host already has the Docker socket — but do not attach other containers to devaloy's network. |

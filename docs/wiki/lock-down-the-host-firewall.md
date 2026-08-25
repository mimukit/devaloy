# Lock down the host firewall

`scripts/host-firewall-lockdown.sh` sets the **host's** own `ufw` policy to deny
all incoming traffic except on the tailnet interface. It is defense-in-depth for
a cloud VPS and skippable on a trusted machine at home.

**This does not protect devaloy.** devaloy has no `ports:` key at all and
publishes nothing, so there is no listening socket on it to firewall. What this
protects is everything else on the host — its sshd, its panel, any service that
came with the distro.

Like `scripts/host-resource-guard.sh`, it runs on the **host**, not inside the
container. `scripts/` is excluded from the Docker build context, so the file is
never in the image and nothing runs it for you. It needs `ufw` and root, neither
of which devaloy has.

## Before you run it

Read this section. The script's guards catch the two common ways to lock
yourself out, but they cannot catch the third.

**It will close ports 80 and 443.** If the host also serves websites, this takes
them offline. The Dokploy page spells out that case:
[Do not run the host firewall script](deploy-with-dokploy.md#8-do-not-run-the-host-firewall-script)
— on a Dokploy host it cuts off the panel on port 3000 and Traefik on 80/443,
taking every other site on that server with them.

Only run it when the host exists for devaloy alone, or when you genuinely want
every service on it reachable over the tailnet only.

## Running it

```sh
sudo ./scripts/host-firewall-lockdown.sh
```

The repo is not checked out as a normal clone on a Dokploy host — Dokploy clones
it under a hash-dependent path for the build — so pull the single file:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/host-firewall-lockdown.sh \
  -o /tmp/host-firewall-lockdown.sh
sudo bash /tmp/host-firewall-lockdown.sh
```

There are no flags. Two environment variables tune it:

| Variable | Default | Effect |
|---|---|---|
| `TS_IFACE` | `tailscale0` | The interface to allow incoming traffic on |
| `ALLOW_NON_TAILNET` | unset | `1` overrides the second anti-lockout guard below |

## The two anti-lockout guards

The script refuses to run rather than risk cutting you off. Both refusals are it
working, not failing.

**1. Tailscale must be up on the host**, with `TS_IFACE` present:

```
Tailscale is not up on this host — refusing to lock down (anti-lockout guard).
```

Without a working tailnet there would be no route left once the rules apply.

**2. Your SSH session must come from a tailnet address** (`100.64.0.0/10`):

```
This SSH session is from <addr>, which is not a tailnet address.
Enabling the firewall now would cut you off.
```

Enabling `ufw` from a session on the host's public IP drops that session
mid-command. Reconnect over Tailscale and run it again. Override only when you
are certain of another way in — console access at the provider, say:

```sh
sudo ALLOW_NON_TAILNET=1 ./scripts/host-firewall-lockdown.sh
```

Neither guard covers the case where **Tailscale itself later breaks on the
host**. After this runs, the tailnet is the only way in, so treat the host's
`tailscaled` the way you already treat devaloy's.

## What it writes

Four `ufw` rules, in this order:

```sh
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw --force enable
```

`--force` is what skips `ufw`'s own interactive "this may disrupt existing ssh
connections" prompt — the guards above are what make that safe.

## Verifying

```sh
sudo ufw status verbose
```

Expect `Default: deny (incoming), allow (outgoing)` and a single rule allowing
anything in on `tailscale0`. Confirm from a second device that you can still
reach the host over the tailnet **before** closing the session you ran it from.

## Undoing it

```sh
sudo ufw disable
```

That drops the firewall entirely and returns the host to accepting whatever it
accepted before. The rules stay stored, so `sudo ufw enable` reinstates them
without re-running the script.

To clear the rules as well:

```sh
sudo ufw --force reset
```

`reset` disables `ufw`, backs the old rules up under `/etc/ufw/`, and returns it
to stock defaults.

## See also

- [The host resource guard](host-resource-guard.md) — the other host-side
  script, and the other half of keeping a small VPS alive.
- [Deploy with Dokploy](deploy-with-dokploy.md#8-do-not-run-the-host-firewall-script)
  — why not to run this one there.
- [Architecture](architecture.md) — why devaloy needs no firewall rule of its own.

_Verified against `main`@`b6bc42b` on 2026-08-25._

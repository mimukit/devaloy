# Lock down the host firewall

`scripts/host-firewall-lockdown.sh` sets the **host's** own `ufw` policy to deny
all incoming traffic except on the tailnet interface. It is defense-in-depth for
a cloud VPS and skippable on a trusted machine at home.

**This does not protect devaloy.** devaloy has no `ports:` key at all and
publishes nothing, so there is no listening socket on it to firewall. What this
protects is the services that listen on the host itself: its sshd, the Docker Swarm ports, any service that came with the distro. It does not protect ports that Docker publishes for a container. See [What it does not close](#what-it-does-not-close).

Like `scripts/host-resource-guard.sh`, it runs on the **host**, not inside the
container. `scripts/` is excluded from the Docker build context, so the file is
never in the image and nothing runs it for you. It needs `ufw` and root, neither
of which devaloy has.

## Before you run it

Read this section. The script's guards catch the two common ways to lock
yourself out, but they cannot catch the third.

**It closes public SSH.** After it runs, port 22 answers only on the tailnet. Anything that reaches the host over SSH on its public IP stops working, and that includes a Dokploy panel on another server that manages this host as a remote server. Point the panel at the host's tailnet address first. [Deploy with Dokploy](deploy-with-dokploy.md#8-the-host-firewall) has the steps.

**It does not close ports that Docker publishes.** On a Dokploy host, Traefik on 80/443 and the panel on 3000 stay reachable from the internet, so the script takes no site offline. It also does not make them private. To close those ports, use the cloud provider's network firewall.

Only run it when the host exists for devaloy alone, or when you want every host service reachable over the tailnet only.

## Running it

```sh
sudo SSH_CONNECTION="$SSH_CONNECTION" ./scripts/host-firewall-lockdown.sh
```

`sudo` strips `SSH_CONNECTION` from the environment, and the script refuses to run when it is empty, because then it cannot tell where your session comes from. Pass it through as above. From the provider console there is no SSH session, so pass `ALLOW_NON_TAILNET=1` instead, and only when you know the tailnet works.

On a VM set up with [Install on a VM](install-on-a-vm.md), run the installer with `--lockdown` instead. It finds your session's `SSH_CONNECTION` and passes it to this script.

The repo is not checked out as a normal clone on a Dokploy host — Dokploy clones
it under a hash-dependent path for the build — so pull the single file:

```sh
curl -fsSL https://raw.githubusercontent.com/mimukit/devaloy/main/scripts/host-firewall-lockdown.sh \
  -o /tmp/host-firewall-lockdown.sh
sudo SSH_CONNECTION="$SSH_CONNECTION" bash /tmp/host-firewall-lockdown.sh
```

There are no flags. Two environment variables tune it:

| Variable | Default | Effect |
|---|---|---|
| `TS_IFACE` | `tailscale0` | The interface to allow incoming traffic on |
| `ALLOW_NON_TAILNET` | unset | `1` overrides the second anti-lockout guard below, and the refusal of an empty `SSH_CONNECTION` |

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

An empty `SSH_CONNECTION` counts as unknown, and the script refuses it too:

```
Cannot tell where this session came from: SSH_CONNECTION is empty.
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

## What it does not close

Docker writes its own `iptables` rules for every port a container publishes, and those rules run before the `ufw` rules. A published port therefore stays open to the internet after the lockdown. On a test host the lockdown closed 22 and the Swarm port 2377, while Traefik's 80/443 and a Redis published on 6371 still answered from outside.

This applies to any container on the host: Traefik, the Dokploy panel, a database with an **External Port**, or a project stack on a native install with `WITH_DOCKER=true`. Two ways to close them:

- Do not publish the port, or publish it on the tailnet address only (`100.x.y.z:6371:6379`). Swarm services cannot bind to one address, so this does not work for a Dokploy database.
- Block the public IP at the cloud provider's network firewall, which filters traffic before it reaches the host. [Deploy with Dokploy](deploy-with-dokploy.md#ovh-edge-network-firewall) has a rule set for OVH.

`sudo ufw status verbose` cannot show this gap. Test from a machine outside the tailnet with `nc -zv -w 5 <public-ip> <port>`.

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
- [Deploy with Dokploy](deploy-with-dokploy.md#8-the-host-firewall)
  — when to run this one there, and the provider firewall that closes the Docker ports.
- [Architecture](architecture.md) — why devaloy needs no firewall rule of its own.

_Verified against `main`@`b6bc42b` on 2026-08-25. The `SSH_CONNECTION` refusal is verified from the code on 2026-10-28._

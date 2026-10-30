# Set up the Cloudflare API token

`wrangler` and `cf` are on every box, installed by mise from `config/mise/config.toml`. This page covers how they authenticate here: one Cloudflare user API token in `.env`, shared by both CLIs, with the account taken from each project's own config.

## Why a token and not a login

Both CLIs log in through a browser by default. `wrangler login` then waits on a callback to `localhost:8976`, and a browser on your laptop cannot reach that port inside the container, so the login never completes.

The device flow avoids the callback, and it is fine for a person at the keyboard:

```sh
wrangler login --device
cf auth login            # the device flow is the default here
```

An agent running overnight needs more than that. An OAuth login expires and depends on a refresh that can fail with nobody there to log in again. Both CLIs read `CLOUDFLARE_API_TOKEN` and use it in place of an OAuth login, so the token is what the box runs on.

## How the token reaches the box

1. You put the token in `.env` as `CLOUDFLARE_API_TOKEN`.
2. `docker-compose.yml` passes it into the container.
3. `step_secrets` in `lib/steps/env.sh` writes it to `~/.devaloy_secrets` (mode 600) on every boot, and every shell on the box sources that file.

The entrypoint deletes and rewrites `~/.devaloy_secrets` on each boot. Do not hand-edit it, because the next boot overwrites your edit.

## The account comes from each project

Leave `CLOUDFLARE_ACCOUNT_ID` unset, on the box and in `.env`. The sites deploy to different accounts, and each project names its own in the `account_id` field of its `wrangler.json`, `wrangler.jsonc` or `wrangler.toml`.

Both CLIs pick the account in this order:

1. `CLOUDFLARE_ACCOUNT_ID` from the environment.
2. `account_id` from the project's wrangler config.
3. The only account the token can see. A token that sees several accounts makes wrangler prompt in a terminal, and fail in a non-interactive run such as an agent's.

A box-wide `CLOUDFLARE_ACCOUNT_ID` wins over step 2 and sends every project to one account. Keep `account_id` in each project's config instead, so the token decides what is allowed and the project decides where it goes.

To run one command against another account, set the variable for that command only:

```sh
CLOUDFLARE_ACCOUNT_ID=<account-id> wrangler kv namespace list
```

## Create the token

It must be a **user** token. An account API token (Manage Account > Account API Tokens) belongs to one account and cannot deploy to the others.

1. Open [My Profile > API Tokens](https://dash.cloudflare.com/profile/api-tokens) in the Cloudflare dashboard. Log in as the user who is a member of every account the projects deploy to.
2. Select **Create Token**, then **Use template** on **Edit Cloudflare Workers**.
3. Name the token after the box, for example `devaloy-wrangler`, so you can tell it apart when you revoke it.
4. Keep the template's permissions. Add the extra ones your projects use, from [What to add](#what-to-add).
5. Under **Account Resources**, select **Include** and each account the box may deploy to. **All accounts** also works, but it gives the box every account you can reach, including ones no project here uses.
6. Under **Zone Resources**, select **Include** and **All zones from an account**, once per account. Pick **Specific zone** instead if the box should touch only the zones its sites use.
7. Leave **Client IP Address Filtering** empty. The box has no fixed egress address to put there.
8. Set a **TTL** end date if you want the token to expire by itself. A year is a sensible default. Without one, the token lives until you revoke it.
9. Select **Continue to summary**, then **Create Token**.
10. Copy the token. Cloudflare shows it once.
11. Put it in `.env` as `CLOUDFLARE_API_TOKEN=` and redeploy with `docker compose up -d`.

Cloudflare's permission reference names the write level `Edit` in some places and `Write` in others. Treat the two words as the same level.

### What the template grants

| Scope | Permission | What needs it |
|---|---|---|
| Account | Workers Scripts: Edit | `wrangler deploy`, `wrangler versions`, secrets |
| Account | Workers KV Storage: Edit | `wrangler kv` namespaces and keys |
| Account | Workers R2 Storage: Edit | `wrangler r2` buckets and objects |
| Account | Workers Tail: Read | `wrangler tail` |
| Account | Account Settings: Read | account lookups during deploy |
| Zone | Workers Routes: Edit | the `routes` and custom domains in a wrangler config |
| User | User Details: Read | `wrangler whoami` |
| User | Memberships: Read | listing the accounts the token can see |

### What to add

Add a row only when a project uses that product.

| Scope | Permission | Add when a project |
|---|---|---|
| Account | Cloudflare Pages: Edit | deploys with `wrangler pages deploy` |
| Account | D1: Edit | runs `wrangler d1 migrations apply --remote` or queries D1 |
| Account | Queues: Edit | creates queues or manages their consumers |
| Account | Hyperdrive: Edit | creates or updates a Hyperdrive config |
| Account | Vectorize: Edit | creates or writes to a Vectorize index |
| Account | Workers AI: Read | runs `wrangler ai` or a remote `wrangler dev` with an AI binding |
| Account | Containers: Edit | deploys a Worker with Containers |
| Zone | Zone: Read | looks up zones with `cf`, beyond what a deploy does |
| Zone | DNS: Edit | changes DNS records with `cf dns` |

A deploy does not need permissions on the resources a Worker binds to. Cloudflare checks those only when the CLI reads or writes the resource itself, for example to apply a D1 migration or to list R2 objects.

## Check it

After the redeploy, open a new shell on the box:

```sh
wrangler whoami   # the token, its permissions, and every account it sees
cf auth whoami
```

Then run `wrangler deployments list` in one project per account. It reads the account from that project's config and changes nothing.

## Change the token

To add a permission or an account, edit the token in the dashboard under My Profile > API Tokens. The secret stays the same, so `.env` and the box need no change.

To replace the token, create the new one, put it in `.env`, redeploy, and then delete the old one in the dashboard.

## Revoke the token

Delete it under My Profile > API Tokens. Cloudflare stops accepting it at once.

Clearing `CLOUDFLARE_API_TOKEN` in `.env` and redeploying also removes it from the box, because the entrypoint rewrites `~/.devaloy_secrets` on every boot.

## What the token can do here

This token can deploy production sites, and agents on this box run unattended in bypass permission mode. Nothing stands between an agent and `wrangler deploy`. Limit **Account Resources** and **Zone Resources** to what the box needs, and leave out any permission no project uses. Run a deploy you are not sure about from your laptop.

## When something is wrong

**"In a non-interactive environment, it is mandatory to specify an account ID".** The project has no `account_id` in its wrangler config, and the token sees more than one account. Add `account_id` to the config. Do not set `CLOUDFLARE_ACCOUNT_ID` on the box.

**An authentication or permission error on one command only.** The token lacks the permission for that product, or the account or zone is not in its resources. Run `wrangler whoami` to see what the token has, then edit the token in the dashboard.

**`wrangler whoami` shows an OAuth login, not the token.** The shell started before the redeploy and has no `CLOUDFLARE_API_TOKEN`. Open a new shell, or run `. ~/.devaloy_secrets`. When the variable is set, both CLIs use it and ignore the stored OAuth login.

_Written against wrangler 4.151.1 and cf 1.0.0-beta.18 on 2026-10-18, from their help output, the cf source and the Cloudflare docs. Not yet run with a live token._

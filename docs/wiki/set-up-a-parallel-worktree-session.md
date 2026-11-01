# Set up a parallel worktree session

This page is the full procedure to run the main checkout of a project and several linked worktrees at the same time, each with its own dev ports, and to open all of them in the laptop browser. It uses `wtports` on the box and `wtforward` on the laptop. [Run worktrees in parallel](run-worktrees-in-parallel.md) explains what each tool does and lists its commands and variables.

The examples use primeshopr, the first project with a `.devports.json`, with the main checkout and 3 linked worktrees. Use the same steps for another project that has a `.devports.json` at its root, and use that project's own install, setup and dev commands.

## Before you start

Check these on the box:

```sh
command -v wtports                          # prints ~/.local/bin/wtports
ls ~/projects/primeshopr/.devports.json     # the project has adopted wtports
cat /sys/fs/cgroup/memory.max               # the container RAM ceiling, in bytes
cat /sys/fs/cgroup/memory.swap.max          # the swap this container may use, in bytes
```

On the laptop, `ssh devaloy` must work and `wtforward` must be installed. Step 1 of [Run worktrees in parallel](run-worktrees-in-parallel.md#1-install-wtforward-on-the-laptop) installs it.

### Size the memory first

Every checkout runs its own set of dev servers, so memory grows with each one. One idle primeshopr checkout (web, admin and api) uses about 2.3 GB of resident memory, and each extra checkout adds about 1.3 GB of anonymous memory to the container. A start uses more for a short time, while Vite bundles the dependencies.

On 2026-11-01, a box with a 6 GB RAM ceiling and about 4.1 GB of swap reached 9.2 GB with 4 primeshopr checkouts. An agent session that ran tests at the same time also used memory. The container restarted twice in that session, and each restart stopped every dev server and every agent session on the box.

For 4 primeshopr checkouts, set `DEVALOY_MEM_LIMIT` to `12g` or more on the host and redeploy. [Size the container resource limits](vm-resource-limits.md) explains the variables. With less memory, run fewer checkouts, and do not run tests or builds in other sessions during the QA.

## 1. Update the main checkout

```sh
cd ~/projects/primeshopr
git pull --ff-only
pnpm install --frozen-lockfile
pnpm env:setup
```

Run the project's migrate command too when the pull changed a migration. For primeshopr, that is `pnpm --filter @repo/db db:migrate`.

The main checkout keeps its default ports (3000, 3001 and 4000 for primeshopr). Do not run `wtports` in it.

## 2. Prepare the linked worktrees

Each linked worktree must contain `.devports.json`, so it must include the commit that added that file. You have two options:

- Make a new worktree from the latest main. Ask an agent to use gitkit, for example "make me a worktree for #42". gitkit cuts the branch from the base and runs the project's `## Worktree setup` block, which installs the packages, writes the env files, and makes and seeds the worktree's own database.
- Sync an existing worktree with main. Ask an agent to use gitkit, for example "sync this branch with main". The sync rebases the branch and force-pushes it, so use it only on a branch that is yours.

Check each worktree:

```sh
git -C ~/projects/primeshopr worktree list
ls ~/worktrees/primeshopr/<branch>/.devports.json
```

Without gitkit, make a worktree by hand and run the project's setup block. For primeshopr, the block is in the `## Worktree setup` section of `AGENTS.md`:

```sh
git -C ~/projects/primeshopr fetch origin --prune
git -C ~/projects/primeshopr worktree add -b <branch> ~/worktrees/primeshopr/<branch> origin/main
cd ~/worktrees/primeshopr/<branch>
export GITKIT_REPO=/home/dev/projects/primeshopr
cp "$GITKIT_REPO/packages/env/.env" packages/env/.env
pnpm install --frozen-lockfile
pnpm env:setup
pnpm db:setup --server
pnpm db:seed
```

## 3. Give each linked worktree its ports

Run `wtports` once in each linked worktree:

```sh
cd ~/worktrees/primeshopr/<branch>
wtports
```

It writes the ports into `apps/web/.env.local`, `apps/admin/.env.local` and `apps/api/.env.local`, and prints one URL for each service. Write down the URLs.

Then check the whole set from any directory:

```sh
wtports list
```

Each linked worktree shows 3 ports from 10000 to 19999, and no port appears twice. The main checkout shows its default ports with `default` in the STATE column. With 3 linked worktrees, the list shows 9 hashed ports.

## 4. Start `wtforward` on the laptop

In a laptop terminal, start it and leave the terminal open:

```sh
wtforward            # the box at the SSH host devaloy
wtforward mybox      # another box, by its SSH host name
```

It forwards each dev port when the server on the box starts to listen. It forwards 3000, 3001, 3002 and 4000 for the main checkout too.

## 5. Start the dev servers one at a time

Start each checkout in its own terminal on the box, for example one tmux window for each checkout. Start the next checkout only after the current one prints a `Local` URL for each of its apps.

```sh
tmux new -s qa
# window 0
cd ~/projects/primeshopr && pnpm dev
# Ctrl+b c opens the next window
cd ~/worktrees/primeshopr/<branch> && pnpm dev
```

Do not start the checkouts at the same time. The Cloudflare Vite plugin in web and api opens a workerd inspector port. It tries 9229 and then takes the next free port. Two checkouts that start at the same moment can choose the same port, and one of them then fails:

```
@repo/web:dev: listen EADDRINUSE: address already in use 127.0.0.1:9234
```

turbo then stops all the apps of that checkout. `.devports.json` does not cover the inspector port, so `wtports` cannot prevent this.

Check the memory after each start, and stop before the total comes near the limit from [Before you start](#before-you-start):

```sh
echo $(( ($(cat /sys/fs/cgroup/memory.current) + $(cat /sys/fs/cgroup/memory.swap.current)) / 1048576 )) MB
```

When all the checkouts are up, `wtports list` shows `live` in the STATE column of each port.

## 6. Check the session in the laptop browser

1. Open the web URL and the admin URL of each checkout. For the main checkout, they are `http://localhost:3000` and `http://localhost:3001`.
2. Log in to admin in each checkout. The primeshopr seed staff user is `admin@primeshopr.test` with the password `primeshopr-dev`.
3. After the last login, reload admin in each of the other checkouts. Each one must still show you as logged in.
4. Open the browser console on an admin page. It must show no CORS error.

Each linked worktree has its own session cookie, because `wtports` writes `AUTH_COOKIE_PREFIX=wt<slug>` into `apps/api/.env.local`. The main checkout uses the default cookie names.

## 7. Stop the session

1. Press `Ctrl+C` in each `pnpm dev` terminal on the box.
2. Press `Ctrl+C` in the `wtforward` terminal on the laptop.
3. Check that no dev server still holds a port: `wtports list` shows no `live` port.

Leave the worktrees in place when you want to run the session again. To remove a worktree, ask an agent to use gitkit, for example "tear down this worktree". gitkit runs the project's `teardown:` block first, which drops the worktree's database. To remove only the port block, run `wtports clean` in the worktree.

## When something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| A linked worktree fails with a `strictPort` error on 3000, 3001 or 4000. | `wtports` did not run in that worktree, so it uses the default ports of the main checkout. | Run `wtports`, then start `pnpm dev` again. |
| `listen EADDRINUSE: address already in use 127.0.0.1:92xx` | Two checkouts started at the same time and took the same inspector port. | Start that checkout again after the others are up. |
| The SSH session closes, and `uptime` on the box shows 0 or 1 minutes. | The container restarted, most likely at its memory limit. | Raise `DEVALOY_MEM_LIMIT`, or run fewer checkouts. |
| A login in one worktree logs you out of another. | The worktree has no `AUTH_COOKIE_PREFIX`, or the dev server started before `wtports` wrote it. | Run `wtports`, then start `pnpm dev` again. |
| A URL does not open on the laptop. | `wtforward` is not running, or a laptop process holds the same port. | Read the `wtforward` output. It prints a warning for each port it skips. |
| A port changed after `wtports`, but the app still uses the old port. | The dev servers read `.env.local` only when they start. | Start `pnpm dev` again. |

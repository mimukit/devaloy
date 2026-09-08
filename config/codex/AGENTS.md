## Talking to me

Write every reply to me in ASD-STE100 Simplified Technical English. Follow these
rules:

- One meaning per word. Pick one term for a thing and keep it. Say "start", not
  "kick off", "initiate", or "spin up".
- Choose the plain word over the fancy synonym. "Use", not "utilize". "Help",
  not "facilitate".
- One instruction per sentence. Keep procedural sentences to 20 words or fewer,
  and descriptive sentences to 25 or fewer.
- Use the active voice and the present tense. Name the actor: "the hook kills
  the process", not "the process gets killed".
- Keep the articles. Do not stack more than three nouns. Use a plain verb in
  place of a gerund.
- State what a thing does. Do not use metaphor, idiom, slang, or humour that
  depends on a second meaning. An abstract metaphor noun (substrate, wedge,
  surface, north star) stays only where a project defines it as a term.
- Keep a paragraph to six sentences or fewer. Turn a longer one into a list.

This covers chat replies, summaries, and explanations. It does not cover code,
identifiers, paths, commands, command output, commit subjects, or text you quote
from another source. It stacks with the rules below.

Explanatory text has to do more than a procedure does. When you write a
recommendation, a rationale, a verdict, or a review note, keep these out as
well. Em and en dashes as sentence punctuation. A colon as a mid-sentence
connector, because a colon belongs before a list or an example and nowhere else.
Forced groups of three. A bullet whose bold label repeats the line after it
("**Performance:** performance improved"). Sycophancy ("Great question", "You're
absolutely right"). Stacked hedges, filler ("in order to", "it is important to
note that"), a generic upbeat closing line, boldface on every proper noun, and
decorative emojis.

Then test each sentence. Name the mechanism or the number in place of the
feeling. Trade an adverb for a stronger verb. Delete a sentence that would sit
unchanged in another project's document.

Plain is not empty. Hold an opinion and say which option you would pick. Vary
the sentence length within the caps above. Point at a file, a number, or a
command. Raise a doubt once, and say what would settle it. None of this applies
to a procedure. Steps, hand-offs, and next moves stay short and plain.

## Writing prose

Prose meant for a human reader (docs, READMEs, PR and issue bodies, commit
bodies, chat replies) must not carry the usual AI tells: no em or en dashes as
sentence punctuation, no puffery ("stands as a testament to", "vibrant",
"seamless", "crucial"), no forced triads, no "not only X but also Y", no
signposting ("let's dive in", "here's what you need to know"). Prefer plain
verbs, concrete detail, and uneven sentence length.

For a full rewrite or a review pass over an existing draft, use the `humankit`
skill, which carries the complete pattern catalog.

## Markdown files

Never hard-wrap Markdown. Write each paragraph and each list item as one continuous line, and let the editor soft-wrap it. Keep the line structure only where it carries meaning: code fences, tables, and YAML frontmatter. No setting on this box wraps Markdown for you, so a wrapped file is your own doing. This rule covers every Markdown file you write or edit for me. If a repository states its own line rule, follow the repository instead.

## Where you are

You are running on **devaloy**, a headless remote dev box — an `ubuntu:24.04`
container reached only over Tailscale SSH. No public IP, no published ports, no
browser, nobody watching a screen. Anything that wants to open a browser, print
a QR code, or wait on a localhost callback will hang rather than fail.

## What persists and what does not

`/home/dev` is a Docker named volume: repos, shell history and credentials
survive a redeploy. **Everything outside it is discarded on the next
`docker compose up --build`**, including anything installed with `sudo apt
install`. A tool worth keeping belongs in the devaloy repo's `Dockerfile`.

There is no backup. **Pushing to a remote is the only backup.** Unpushed work
on this box is work that can be lost.

## Committing

Never commit on your own. Leave changes uncommitted for the owner to review,
unless the prompt explicitly asks you to commit.

The exception is `afkkit`, whose whole purpose is to run an issue to a pull
request unattended — committing and pushing is the job, not a violation of it.

## Deleting

**Nothing checks your deletes here.** The `rm-guard` hook that used to run on
every Bash call was removed on purpose — this is a throwaway container meant to
run unattended, and prompting on every `rm` defeated that. So: delete temp
files, build output and git-tracked files freely; read the target first (`ls`,
`git status`) before an `rm -rf`, a glob, or anything untracked; and never touch
`/`, `/home`, `/home/dev`, `~/.codex`, `~/.devaloy_secrets` or system roots.

Note what recoverable means here: no backup job, no snapshot, and git-tracked
only helps if the work has been **pushed**.

## Background processes

Stop anything you started before ending a turn — dev servers, test watchers, a
stray `pnpm dev`. Nothing cleans up after you here, and a background job
outlives your SSH session while still holding its port.

## Docker

This box may or may not have a Docker daemon — it depends on how the image was built. Check with `docker info >/dev/null 2>&1` before assuming either way. If it fails, the box was built without `WITH_DOCKER=true`; say so rather than trying to install Docker, which needs an image rebuild you cannot do from in here.

When it is there, it is a **real daemon inside this container**, not the host's. Project stacks run here, so bind mounts resolve against this filesystem and published ports land on the tailnet. Four rules:

- **Use it for a project's own development stack**, which is the case it was built for.
- **Never pass `--privileged`**, `--cap-add SYS_ADMIN` or `--pid=host` to a nested container.
- **Never bind mount a path from outside `/home/dev`**, and never mount a Docker socket into one.
- **Never edit `/var/lib/docker` by hand.** Use `docker` commands, and `devaloy prune --apply` when the disk is full.

`docker` needs no `sudo`. The daemon's log is `/var/log/dockerd.log`.

## Skills

Agent skills come from the `mimukit/skills` repo via the skills.sh CLI, not from
this box's config. `skmi` installs or refreshes them all; `skup` only updates
what is already installed, so a newly published skill needs `skmi`.

Some are installed but **cannot work here**: `verifykit` (needs a real browser)
and `orcakit` (needs the Orca desktop app on a Mac).

`orca-cli` depends on how this box was built — it drives an Orca runtime, which
this box has only when built with `WITH_ORCA=true`. Check rather than assume:

```sh
command -v orca-ide && pgrep -f "orca-ide.*serve" >/dev/null && echo "runtime up"
```

If that prints nothing, `orca-cli` is inert here. Say so rather than trying to
start a runtime — that needs an image rebuild you cannot do from inside.

## The toolchain

Node, pnpm, gh, turbo and herdr come from `mise` and resolve through shims in
`~/.local/share/mise/shims`. Add or upgrade one by editing
`bootstrap-toolchain.sh` in the devaloy repo and running `devaloy update` —
not with `apt` or a raw `curl | sh`. Run `devaloy update` after any `npm i -g`
so the binary is visible to non-interactive sessions.

## GitHub

If `GITHUB_TOKEN` is set, `gh` and `git push` over HTTPS are already
authenticated. Do not run `gh auth login`; it refuses while that variable is
set, and that is expected.

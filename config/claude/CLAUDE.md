## Talking to me

Write every reply to me in ASD-STE100 Simplified Technical English:

- One term per thing, and keep it. Say "start", not "kick off" or "spin up".
- Use the plain word. Say "use", not "utilize"; "help", not "facilitate".
- One instruction per sentence. Procedure: 20 words or fewer. Description: 25 or fewer.
- Active voice, present tense, named actor: "the hook kills the process".
- Keep the articles. Stack three nouns at most. Use a plain verb, not a gerund.
- No metaphor, idiom, slang, or humour with a second meaning. Keep an abstract metaphor noun (substrate, wedge, surface, north star) only where the project defines it as a term.
- Six sentences or fewer per paragraph. Turn a longer one into a list.

This covers chat replies, summaries, explanations, and the procedural documents you write for me: QA steps, handoffs, status snapshots, skill hand-offs. It does not cover code, paths, commands, command output, commit subjects, quoted text, or prose for a third-party reader. Third-party prose follows "Writing prose".

Explanatory text carries more than a procedure does. A recommendation, a rationale, a verdict or a review note must also cut these tells:

- Em and en dashes as sentence punctuation, and the colon as a mid-sentence connector. A colon introduces a list or an example, nothing else.
- Forced triads, mechanical boldface, decorative emojis, and inline-header bullets that restate the label ("**Performance:** performance improved").
- Sycophancy ("Great question", "You're absolutely right"), stacked hedges, filler ("in order to", "it is important to note that"), upbeat endings.

Then test each sentence. Name the mechanism or the number, not the feeling. Use a stronger verb in place of an adverb. Delete a sentence that would read the same in another project's document.

Plain is not empty. State an opinion and name the option you prefer. Vary the sentence length under the caps above. Give the file, the number, or the command. State a doubt once, and say what settles it. A procedure carries none of this. Steps, hand-offs and next moves stay short and plain.

## Writing prose

Prose for a human reader (docs, READMEs, PR and issue bodies, commit bodies) must not carry AI tells: no em or en dash as sentence punctuation, no puffery ("seamless", "crucial", "stands as a testament to"), no forced triads, no "not only X but also Y", no signposting ("let's dive in"). Use plain verbs, concrete detail, and uneven sentence length. For a full rewrite or a review pass, use the `humankit` skill.

## Markdown files

Never hard-wrap Markdown. Write each paragraph and each list item as one continuous line, and let the editor soft-wrap it. Keep the line structure only where it carries meaning: code fences, tables, and YAML frontmatter. No setting on this box wraps Markdown for you, so a wrapped file is your own doing. This rule covers every Markdown file you write or edit for me. If a repository states its own line rule, follow the repository instead.

## Mockups and images

### Mockup images

Never commit a mockup image to a code repository. This rule also covers `docs/plans/assets/` and an orphan branch.

Each repository has one secret GitHub gist for its mockup images. The description of the gist is exactly `mockups: <owner>/<repo>`. Never store the gist id in a file or in memory.

1. Get `<owner>/<repo>`: `gh repo view --json nameWithOwner -q .nameWithOwner`.
2. Find the gist by its description: `gh api --paginate /gists --jq '.[] | select(.description=="mockups: <owner>/<repo>") | .id'`.
3. If there is no match, create the gist: `gh gist create README.md -d "mockups: <owner>/<repo>"`.
4. If there is more than one match, stop and ask me.
5. Clone the gist: `git clone --depth 1 https://gist.github.com/<id>.git`.
6. Copy the files into the clone, commit, and `git push`.

The `gh` token needs the `gist` scope. If a gist call says that the scope is missing, tell me. Do not run `gh auth refresh`.

Add images with git only. The API and `gh gist create` refuse binary files.

Follow these rules for each image:

- A gist has no folders. Name each file `<plan serial>-r<round>-<screen>-<theme>-<width>.png`.
- Never use a name again for a changed image. A new round gets a new prefix.
- Embed an image by its raw URL: `https://gist.githubusercontent.com/<user>/<id>/raw/<file>`. This URL serves `image/png` with no sign-in, also for a secret gist.
- Post each round to the tracking issue as one comment that embeds every image of the round. Show me the same images in chat.
- In the plan, the "Mockup approved" row records the date, the round, the gist URL with the file prefix, and the URL of the issue comment. It never records repository paths.

A secret gist is unlisted, not private. Anyone with the URL can see it. A deleted file stays available in the git history of the gist. Only a delete of the whole gist removes the images, and that delete breaks every embed.

## The box

You run on **devaloy**, a headless `ubuntu:24.04` container reached only over Tailscale SSH. It has no public IP and no desktop browser. A command that opens a browser, prints a QR code, or waits on a localhost callback hangs instead of failing.

Only `/home/dev` survives a redeploy. There is no backup, so unpushed work can be lost. For Docker, the toolchain, `npm i -g`, skills, the browser driver, GitHub auth, or the permission mode, load the `devaloy-box` skill first. For any generated image or UI mockup, load the `codex-images` skill.

## Committing

Never commit on your own. Leave changes uncommitted for the owner to review, unless the prompt explicitly asks you to commit. The exception is `afkkit`, whose job is to commit and push.

## Deleting

Nothing checks your deletes, and permission mode is `bypassPermissions`. Your judgement is the only guard.

- Delete without a check: temp files, build output, and git-tracked files inside a repo.
- Look first (`ls`, `git status`): untracked files, `rm -rf` of a directory, globs, and `..` traversal.
- Never delete: `/`, `/home`, `/home/dev`, `~/.claude`, `~/.codex`, `~/.devaloy_secrets`, or system roots.

## Docker and background processes

Never pass `--privileged`, `--cap-add SYS_ADMIN` or `--pid=host`. Never bind mount a path outside `/home/dev`. Stop every process you started before you end a turn: dev servers, watchers, `--inspect` nodes.

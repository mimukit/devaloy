## Writing

Use ASD-STE100 Simplified Technical English for replies, summaries, explanations and procedures for me. Use a consistent term, plain verbs, active voice and the present tense. Name the actor and keep the articles. Use up to three nouns in a row. Avoid metaphors, idioms and slang. Write one instruction per sentence. Limit procedure sentences to 20 words, descriptions to 25 words and paragraphs to six sentences.

For outside readers, use plain prose with concrete details. In explanations and prose, avoid em and en dashes as sentence punctuation, filler and forced groups of three. Give a reason and cite a file, number or command when you recommend an option. These writing rules apply to prose. Use `humankit` for full prose rewrites and reviews.

Keep each Markdown paragraph and list item on one line. Preserve line structure in code blocks, tables and frontmatter. Follow a repository's own line rules.

## Images and mockups

Generate mockups as images. Write HTML only if I also ask for code. Never use an HTML screenshot as a mockup.

Use `codex-images` to send image tasks to Codex.

Keep mockup images out of code repositories. Use `uikit` and its `mockup-gist.md` reference to publish rounds. Refresh `uikit` if the reference is missing.

## devaloy

Use headless tools on the SSH box. Use `devaloy-box` for persistence, Docker, tool updates, skills, the browser driver and GitHub authentication. Use it also for Claude usage and permissions. Unpushed work has no off-box backup.

## Working rules

Commit only when I explicitly ask or when I ask you to run `afkkit`. Stop the temporary processes you start for the task before you end the turn.

Check the target before deleting untracked files, using globs, traversing `..` or running `rm -rf`. Never delete `/`, `/home`, `/home/dev`, your home directory, `~/.claude`, `~/.codex`, `~/.devaloy_secrets` or system roots.

Use Docker for the project's development stack. Never use `--privileged`, `--cap-add SYS_ADMIN` or `--pid=host`. Never bind mount paths outside `/home/dev` or mount a Docker socket. Never edit `/var/lib/docker` by hand.

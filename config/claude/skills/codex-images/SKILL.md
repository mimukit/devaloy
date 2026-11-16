---
name: codex-images
description: >-
  Send every image task to Codex: a UI mockup, a screen variant, an icon, an illustration, or any other generated picture. Use whenever the user asks for an image or a mockup, before you write any HTML for it.
---

# codex-images

Claude Code cannot generate images. Codex can, so send every image task to Codex.

- Do not write an HTML mockup page and screenshot it to make or iterate on a design. Write HTML only when the request asks for code.
- Start a Codex sub-agent for each image task, on the newest Sol model. Today that is `gpt-6.1-sol`. To confirm the newest, read the `*-sol` slugs in `~/.codex/models_cache.json`.
- In T3 Code, use `delegate_task` with the Codex provider and the Sol model. Elsewhere, run `codex exec -m gpt-6.1-sol "<prompt>"` in the project directory.
- Give the sub-agent the screen, the content, the size, and the path for the PNG. Codex also keeps a copy under `~/.codex/generated_images/`.
- Show the user the image, take their feedback, and send the next round to Codex. Repeat until the user approves the mockup.
- If `command -v codex` prints nothing, or Codex is not signed in, say so. Do not fall back to an HTML screenshot.

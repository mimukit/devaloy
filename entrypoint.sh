#!/usr/bin/env bash
set -euo pipefail

DEV_USER="dev"
DEV_HOME="/home/${DEV_USER}"
TS_STATE_DIR="${TS_STATE_DIR:-/var/lib/tailscale}"
TS_SOCKET="/var/run/tailscale/tailscaled.sock"
CONFIG_SRC="/opt/devaloy/config"
# Version pins live in bootstrap-toolchain.sh; these are only forwarded, so an
# empty value here falls through to that script's default.

log() { echo "[entrypoint] $*"; }

# Run a command as the dev user under a plain sh. The explicit -s matters now
# that the dev user's login shell is zsh: without it every helper below would
# run through a shell whose startup files this script is in the middle of
# rewriting. -l gives a clean environment and a correct HOME.
as_dev() { su -l -s /bin/sh "${DEV_USER}" -c "$1"; }

# --- shell env: toolchain PATH + OOM reset, for EVERY shell ---
# Written before tailscaled comes up, so the very first session that lands
# already has it. Ubuntu's stock .bashrc bails out early on non-interactive
# shells, so this is sourced from the TOP of .bashrc, above that guard; for zsh
# it hangs off .zshenv, which zsh sources for *every* invocation including
# `ssh devaloy '<cmd>'`. mise shims resolve versions at exec time, so no
# interactive `mise activate` is needed. link-shims covers whatever is left.
ENV_SNIPPET="${DEV_HOME}/.devaloy_env"
cat > "${ENV_SNIPPET}" <<'EOF'
# Idempotent: this file is reachable from .zshenv, .zshrc and .bashrc, and a
# blind prepend would stack duplicate entries onto PATH on every nested shell.
# Listed back-to-front because each iteration prepends: the last one processed
# ends up first, and ~/.local/bin has to win — it is where a hand-run vendor
# installer puts things, and that copy should shadow the packaged one.
for _devaloy_dir in "$HOME/.local/share/mise/shims" "$HOME/.local/bin"; do
  case ":$PATH:" in
    *":$_devaloy_dir:"*) ;;
    *) PATH="$_devaloy_dir:$PATH" ;;
  esac
done
unset _devaloy_dir
export PATH

# Tokens live in a separate 0600 file so this one stays safe to cat.
[ -f "$HOME/.devaloy_secrets" ] && . "$HOME/.devaloy_secrets"

# The container starts at a negative oom_score_adj (see compose.yml) to keep
# tailscaled off the OOM killer's list. Raise every session back to 0 so a
# runaway build inherits 0 and is killed before the process that keeps you
# connected. Raising is unprivileged; only lowering needs CAP_SYS_RESOURCE.
echo 0 > /proc/self/oom_score_adj 2>/dev/null || true
EOF
chown "${DEV_USER}:${DEV_USER}" "${ENV_SNIPPET}"

if ! grep -qF '.devaloy_env' "${DEV_HOME}/.bashrc" 2>/dev/null; then
  touch "${DEV_HOME}/.bashrc"
  {
    # shellcheck disable=SC2016  # $HOME must stay literal — the dev user's
    # shell expands it at login, not this script.
    printf '%s\n' '[ -f "$HOME/.devaloy_env" ] && . "$HOME/.devaloy_env"'
    cat "${DEV_HOME}/.bashrc"
  } > "${DEV_HOME}/.bashrc.new"
  mv "${DEV_HOME}/.bashrc.new" "${DEV_HOME}/.bashrc"
  chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.bashrc"
fi

if ! grep -qF '.devaloy_env' "${DEV_HOME}/.zshenv" 2>/dev/null; then
  # shellcheck disable=SC2016  # as above, $HOME stays literal.
  echo '[ -f "$HOME/.devaloy_env" ] && . "$HOME/.devaloy_env"' >> "${DEV_HOME}/.zshenv"
  chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.zshenv"
fi

# --- retire the old login banner ---
# It printed on every interactive session and earned nothing. Removed from the
# image, and swept out of home volumes created before that change.
rm -f "${DEV_HOME}/.devaloy_profile"
if [ -f "${DEV_HOME}/.bashrc" ] && grep -qF '.devaloy_profile' "${DEV_HOME}/.bashrc"; then
  sed -i '/\.devaloy_profile/d' "${DEV_HOME}/.bashrc"
fi

# --- tokens ---
# Written to a file rather than relied on from the container environment:
# tailscaled spawns login shells itself, and what it forwards from PID 1's
# environment is its business, not a contract. Rewritten from scratch on every
# boot, so clearing a variable in .env and redeploying really does revoke it.
SECRETS_SNIPPET="${DEV_HOME}/.devaloy_secrets"
rm -f "${SECRETS_SNIPPET}"

write_secret() {
  name="$1"; value="$2"
  [ -n "${value}" ] || return 0
  [ -f "${SECRETS_SNIPPET}" ] || \
    install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${SECRETS_SNIPPET}"
  # Single-quote the value and escape any embedded quote, so a token with shell
  # metacharacters cannot execute anything when this file is sourced.
  printf "export %s='%s'\n" "${name}" \
    "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")" >> "${SECRETS_SNIPPET}"
  log "${name} wired into the dev shell environment"
}

write_secret GITHUB_TOKEN "${GITHUB_TOKEN:-}"
# Authenticates Claude Code with no `/login` from inside the box. The CLI reads
# this variable itself, so nothing else has to be configured — but note it sits
# BELOW ANTHROPIC_API_KEY and ANTHROPIC_AUTH_TOKEN in Claude Code's precedence
# order and ABOVE ~/.claude/.credentials.json, so a hand-run `/login` on the box
# is silently ignored while this is set. It is a static one-year token that
# never refreshes itself; when it lapses, re-run `claude setup-token` on your
# laptop and redeploy.
write_secret CLAUDE_CODE_OAUTH_TOKEN "${CLAUDE_CODE_OAUTH_TOKEN:-}"

# --- ntfy push-notification config for hooks ---
# agent-push reads ~/.config/agent-push.env rather than the shell environment,
# because Orca spawns panes via `su -l -s /bin/sh`, which sources neither
# .zshenv nor .bashrc — so ~/.devaloy_secrets is not reliably in a hook's env.
# Rewritten from scratch every boot (like ~/.devaloy_secrets above), so clearing
# NTFY_TOPIC in .env and redeploying really does turn the feature off. Only
# written when a topic is set; absent, agent-push's own no-topic gate keeps it
# inert. .env's NTFY_* names map onto the script's PUSH_* keys here.
PUSH_ENV_FILE="${DEV_HOME}/.config/agent-push.env"
rm -f "${PUSH_ENV_FILE}"
push_write() {
  name="$1"; value="$2"
  [ -n "${value}" ] || return 0
  mkdir -p "${DEV_HOME}/.config"
  chown "${DEV_USER}:${DEV_USER}" "${DEV_HOME}/.config" 2>/dev/null || true
  [ -f "${PUSH_ENV_FILE}" ] || \
    install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${PUSH_ENV_FILE}"
  # Single-quote and escape embedded quotes, so a value with shell
  # metacharacters cannot execute anything when agent-push sources this file.
  printf "%s='%s'\n" "${name}" \
    "$(printf '%s' "${value}" | sed "s/'/'\\\\''/g")" >> "${PUSH_ENV_FILE}"
}
if [ -n "${NTFY_TOPIC:-}" ]; then
  push_write PUSH_NTFY_TOPIC "${NTFY_TOPIC}"
  push_write PUSH_NTFY_URL   "${NTFY_SERVER:-}"
  push_write PUSH_NTFY_TOKEN "${NTFY_TOKEN:-}"
  log "ntfy push notifications enabled (topic configured; ~/.config/agent-push.env written)"
fi

# --- managed dotfiles (zsh, Claude Code, Codex) ---
# The repo is the source of truth: every file shipped under config/ is copied
# over its counterpart in /home/dev on each boot, so editing one in the repo
# and redeploying actually changes the box. The copy MERGES rather than
# replaces, so files the repo does not ship — ~/.zshrc.local, credentials,
# session history, skills you added by hand — are left alone.
seed_config() {
  src="$1"; dest="$2"
  [ -d "${src}" ] || return 0
  as_dev "mkdir -p '${dest}' && cp -R '${src}/.' '${dest}/'"
}
if [ -d "${CONFIG_SRC}" ]; then
  as_dev "cp -f '${CONFIG_SRC}/zsh/zshrc' '${DEV_HOME}/.zshrc'"
  seed_config "${CONFIG_SRC}/claude" "${DEV_HOME}/.claude"
  seed_config "${CONFIG_SRC}/codex"  "${DEV_HOME}/.codex"
  # Shared agent scripts (agent-push). ~/.local/bin rather than either agent's
  # directory, because both agents run the same script — the hook entries in
  # settings.json and hooks.json both point here. This directory is already on
  # PATH via .devaloy_env, and mise owns it too, so the merge copy matters: a
  # replace would take out mise's own binary.
  seed_config "${CONFIG_SRC}/bin" "${DEV_HOME}/.local/bin"
  # The delete guard was removed: this box is a disposable container, and a
  # PreToolUse prompt on every rm defeats the point of running agents here
  # unattended. Seeding is a merge, so copies from before the removal would
  # otherwise sit on the persistent volume forever, unwired but on PATH.
  as_dev "rm -f '${DEV_HOME}/.local/bin/agent-hook' '${DEV_HOME}/.local/bin/rm-guard'"
  log "Managed dotfiles synced from ${CONFIG_SRC}"
fi

# --- Claude Code onboarding stamp ---
# The token authenticates the CLI, but the interactive TUI gates its first-run
# "Select login method" screen on hasCompletedOnboarding in ~/.claude.json, not
# on auth state — so `claude auth status` reports loggedIn while `claude` still
# asks you to log in. Stamping the flag skips the screen. Only done when the
# token is set: without one, that screen is the way you actually log in.
# ~/.claude.json also holds MCP servers and per-project history, so this merges
# into whatever is there rather than writing the file fresh.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  CLAUDE_JSON="${DEV_HOME}/.claude.json"
  as_dev "
    if [ -s '${CLAUDE_JSON}' ] && jq -e . '${CLAUDE_JSON}' >/dev/null 2>&1; then
      jq '.hasCompletedOnboarding = true' '${CLAUDE_JSON}' > '${CLAUDE_JSON}.tmp' &&
        mv '${CLAUDE_JSON}.tmp' '${CLAUDE_JSON}'
    else
      printf '%s\n' '{\"hasCompletedOnboarding\": true}' > '${CLAUDE_JSON}'
    fi
  "
  log "Claude Code onboarding marked complete (token auth in use)"
fi

# --- tailscaled + Tailscale SSH (started FIRST, before the slow bootstrap) ---
# Ordering matters: the toolchain install takes minutes on a cold volume, and
# there is no sshd fallback any more. Bringing the tailnet up first means the
# box is reachable *during* that window rather than after it.
mkdir -p "${TS_STATE_DIR}" "$(dirname "${TS_SOCKET}")"

log "Starting tailscaled"
tailscaled \
  --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket="${TS_SOCKET}" \
  --tun=tailscale0 &
TAILSCALED_PID=$!

for _ in $(seq 1 30); do
  [ -S "${TS_SOCKET}" ] && break
  sleep 1
done
if [ ! -S "${TS_SOCKET}" ]; then
  log "WARNING: tailscaled socket never appeared — check NET_ADMIN and /dev/net/tun."
fi

# --accept-dns defaults to false: letting Tailscale rewrite /etc/resolv.conf in
# a container clobbers Docker's own resolver. Set TS_ACCEPT_DNS=true if you want
# MagicDNS resolution *from* the box.
# --timeout is load-bearing, not defensive: with no authkey and no saved state,
# `tailscale up` prints a login URL and blocks FOREVER. That would wedge the
# entrypoint before the toolchain bootstrap ever runs. Fail instead, and let the
# warning path below tell you how to finish the login by hand.
up_args=(--ssh --timeout=90s --hostname="${TS_HOSTNAME:-devaloy}")
if [ "${TS_ACCEPT_DNS:-false}" = "true" ]; then
  up_args+=(--accept-dns=true)
else
  up_args+=(--accept-dns=false)
fi
# On a redeploy the node identity is already in the state volume, so the authkey
# is optional — only pass it when one is set.
if [ -n "${TS_AUTHKEY:-}" ]; then
  up_args+=(--authkey="${TS_AUTHKEY}")
fi

if tailscale --socket="${TS_SOCKET}" up "${up_args[@]}"; then
  log "Tailscale SSH is up as ${TS_HOSTNAME:-devaloy} ($(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1))"
else
  # Deliberately non-fatal. Restart-looping would not fix a bad authkey or a
  # missing ACL rule, and it would destroy the one diagnostic path left.
  log "WARNING: tailscale up failed — this box is NOT reachable over the tailnet."
  if [ -z "${TS_AUTHKEY:-}" ]; then
    log "WARNING: TS_AUTHKEY is empty. Look further up this log for a"
    log "WARNING: 'To authenticate, visit: ...' URL and open it, or set the key."
  fi
  log "WARNING: recover from the Docker host with:"
  log "WARNING:   docker compose exec devaloy tailscale up --ssh"
fi

# --- mise bootstrap + pinned toolchain (runs as dev) ---
# The skip-if-already-installed decision lives in bootstrap-toolchain.sh, not
# here: it is gated on that script's TOOLSET_REVISION, and only the script knows
# what revision it ships. Keeping the check next to the tool list is what stops
# a newly added tool from being skipped forever on a volume that was
# provisioned before it existed.
#
# Deliberately NOT fatal: a network blip on first boot must not take the box
# down. The revision marker is only written on success, so a later boot (or
# `devaloy-update`) retries cleanly.
log "Checking the mise toolchain"
if as_dev "MISE_NODE_VERSION='${MISE_NODE_VERSION:-}' \
    MISE_HERDR_VERSION='${MISE_HERDR_VERSION:-}' \
    /usr/local/bin/bootstrap-toolchain.sh"; then
  log "Toolchain ready"
else
  log "WARNING: toolchain bootstrap failed — the box is still reachable."
  log "WARNING: once you are in, re-run it with: devaloy-update"
fi

# Make the toolchain resolvable from sessions that never source .bashrc.
DEV_HOME="${DEV_HOME}" /usr/local/bin/link-shims || \
  log "WARNING: link-shims failed — non-interactive commands may not find the toolchain."

# --- gh and git over HTTPS via GITHUB_TOKEN ---
# Run after link-shims because that is what puts gh on root's PATH.
#
# gh's credential is stored on disk rather than left to the environment, and
# that is the whole point of this block. gh does read GITHUB_TOKEN by itself,
# but only from a process that HAS it — and the token deliberately lives in
# ~/.devaloy_secrets (see the tokens block above), which nothing sources except
# .zshenv and .bashrc. Orca's headless server is started through
# `su -l -s /bin/sh`, which reads neither and which clears the environment it
# inherited from PID 1, so every `gh` that server shells out for — the mobile
# app's repo, branch, PR and issue pickers — came back with "To get started with
# GitHub CLI, please run: gh auth login" while an interactive terminal on the
# same box worked fine. Storing it takes the environment out of the loop for
# every consumer at once, instead of teaching each one to source the file.
#
# hosts.yml is rebuilt from scratch on every boot, exactly like
# ~/.devaloy_secrets — removed here unconditionally, ABOVE the token check, so
# clearing GITHUB_TOKEN in .env and redeploying genuinely revokes gh's access
# rather than leaving a working credential behind in the home volume.
rm -f "${DEV_HOME}/.config/gh/hosts.yml"

if [ -n "${GITHUB_TOKEN:-}" ] && [ -x /usr/local/bin/gh ]; then
  # The token is read from the 0600 file and piped on stdin, never passed as an
  # argument, where it would be readable in /proc for the life of the call.
  # GITHUB_TOKEN has to be unset around the call itself: gh refuses to write
  # hosts.yml while an environment token is set, on the grounds that the
  # environment would outrank the stored credential anyway.
  # shellcheck disable=SC2016  # $HOME and $GITHUB_TOKEN belong to the dev shell.
  if as_dev '. "$HOME/.devaloy_secrets"; _t="$GITHUB_TOKEN"; unset GITHUB_TOKEN GH_TOKEN; printf "%s" "$_t" | gh auth login --with-token' 2>/dev/null; then
    log "gh authenticated to GitHub (credential stored, not environment-bound)"
  else
    log "WARNING: gh auth login failed — the Orca app's GitHub pickers, and any"
    log "WARNING: other gh call from outside a login shell, will report that you"
    log "WARNING: must run 'gh auth login' first."
  fi

  # Teaches git to ask gh for credentials, so `git push` works without a second
  # login. The helper it installs re-invokes gh, which is why this runs after
  # the login above — with hosts.yml in place the helper answers from any
  # process, including one Orca spawned, rather than only from a login shell.
  # Still sources the secrets itself so that a failed login above costs the
  # pickers but not `git push`, which the environment token alone can carry.
  # shellcheck disable=SC2016  # $HOME is expanded by the dev user's shell.
  if as_dev '. "$HOME/.devaloy_secrets" && gh auth setup-git' 2>/dev/null; then
    log "git configured to authenticate to GitHub through gh"
  else
    log "WARNING: gh auth setup-git failed — 'git push' over HTTPS may prompt."
  fi
fi

# --- git identity ---
# Without this every commit from the box dies with "Author identity unknown",
# which an unattended agent cannot recover from. Written with `git config
# --global`, one key at a time, rather than by templating ~/.gitconfig: the file
# lives in the home volume and may hold aliases, diff tools and other settings
# added by hand, and only the keys below are ours to own.
#
# Runs after the gh block on purpose — the fallback path shells out to gh.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
git_cfg() { as_dev "git config --global $(sq "$1") $(sq "$2")"; }

GIT_NAME="${GIT_AUTHOR_NAME:-}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-}"

# Fallback: ask GitHub who the token belongs to. The address is the account's
# ID+login noreply form rather than .email, because .email is null unless the
# profile email is public, and the noreply address is ALWAYS a verified address
# on the account — which is what GitHub requires before it will mark a signed
# commit as Verified.
if { [ -z "${GIT_NAME}" ] || [ -z "${GIT_EMAIL}" ]; } &&
   [ -n "${GITHUB_TOKEN:-}" ] && [ -x /usr/local/bin/gh ]; then
  # shellcheck disable=SC2016  # $HOME is expanded by the dev user's shell.
  GH_USER_JSON="$(as_dev '. "$HOME/.devaloy_secrets" && gh api user' 2>/dev/null || true)"
  if [ -n "${GH_USER_JSON}" ]; then
    # `|| true` inside each substitution, not after: gh can hand back a body
    # that is not the object jq expects, and a bare jq failure would take the
    # whole entrypoint down under `set -e` before tailscaled is even waited on.
    [ -n "${GIT_NAME}" ] || GIT_NAME="$(printf '%s' "${GH_USER_JSON}" |
      jq -r '.name // .login // empty' 2>/dev/null || true)"
    [ -n "${GIT_EMAIL}" ] || GIT_EMAIL="$(printf '%s' "${GH_USER_JSON}" |
      jq -r 'select(.id and .login) | "\(.id)+\(.login)@users.noreply.github.com"' 2>/dev/null || true)"
  fi
fi

if [ -n "${GIT_NAME}" ] && [ -n "${GIT_EMAIL}" ]; then
  git_cfg user.name  "${GIT_NAME}"
  git_cfg user.email "${GIT_EMAIL}"
  log "git identity set to ${GIT_NAME} <${GIT_EMAIL}>"
else
  log "WARNING: no git identity — commits from this box will fail with"
  log "WARNING: 'Author identity unknown'. Set GIT_AUTHOR_NAME and"
  log "WARNING: GIT_AUTHOR_EMAIL in .env, or supply a GITHUB_TOKEN."
fi

# --- SSH-signed commits ---
# GitHub shows a commit as Unverified unless it carries a signature from a key
# registered on the account. SSH signing rather than GPG: one key file, no
# gpg-agent, no passphrase daemon to keep alive in a container.
#
# Rebuilt from scratch on every boot, exactly like ~/.devaloy_secrets — clearing
# GIT_SIGNING_SSH_KEY in .env and redeploying really does remove the key AND
# turn commit.gpgsign back off, so a later commit does not fail on a key that is
# no longer there.
SIGNING_KEY="${DEV_HOME}/.ssh/devaloy_signing"
ALLOWED_SIGNERS="${DEV_HOME}/.config/git/allowed_signers"
rm -f "${SIGNING_KEY}" "${SIGNING_KEY}.pub" "${ALLOWED_SIGNERS}"

if [ -n "${GIT_SIGNING_SSH_KEY:-}" ]; then
  # Accepts the key either base64-encoded on one line (the documented form —
  # a .env value cannot portably hold the newlines a PEM block needs) or as
  # literal PEM, for the case where it arrives through some other channel.
  KEY_MATERIAL="${GIT_SIGNING_SSH_KEY}"
  case "${KEY_MATERIAL}" in
    *"PRIVATE KEY"*) ;;
    *) KEY_MATERIAL="$(printf '%s' "${KEY_MATERIAL}" | tr -d ' \n' | base64 -d 2>/dev/null || true)" ;;
  esac

  case "${KEY_MATERIAL}" in
    *"PRIVATE KEY"*)
      as_dev "mkdir -p '${DEV_HOME}/.ssh' && chmod 700 '${DEV_HOME}/.ssh'"
      install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${SIGNING_KEY}"
      # Exactly one trailing newline: OpenSSH rejects a private key without it,
      # and command substitution above already ate any that were there.
      printf '%s\n' "${KEY_MATERIAL}" > "${SIGNING_KEY}"

      # -P '' and </dev/null together are what stop this hanging forever on a
      # passphrase prompt: an encrypted key fails fast here instead, which is
      # the right outcome — nothing in this container can type a passphrase.
      if as_dev "ssh-keygen -y -P '' -f '${SIGNING_KEY}' > '${SIGNING_KEY}.pub'" </dev/null 2>/dev/null &&
         [ -s "${SIGNING_KEY}.pub" ]; then
        git_cfg gpg.format ssh
        # The PRIVATE key path, not the .pub: git hands this straight to
        # `ssh-keygen -Y sign -f`, which needs the secret half and finds the
        # public one beside it.
        git_cfg user.signingkey "${SIGNING_KEY}"
        git_cfg commit.gpgsign true
        # Tags too — GitHub verifies those on the release page as well.
        git_cfg tag.gpgsign true

        # Only affects local `git log --show-signature` output, which without it
        # reports every one of your own commits as from an unknown signer.
        # GitHub does not read this file; it checks the key on your account.
        as_dev "mkdir -p '$(dirname "${ALLOWED_SIGNERS}")'"
        install -m 600 -o "${DEV_USER}" -g "${DEV_USER}" /dev/null "${ALLOWED_SIGNERS}"
        printf '%s %s\n' "${GIT_EMAIL:-dev}" "$(cat "${SIGNING_KEY}.pub")" > "${ALLOWED_SIGNERS}"
        git_cfg gpg.ssh.allowedSignersFile "${ALLOWED_SIGNERS}"

        log "commits will be SSH-signed with $(ssh-keygen -lf "${SIGNING_KEY}.pub" 2>/dev/null | awk '{print $2}')"

        # --- register the public half on GitHub as a signing key ---
        # This is what turns the badge from Unverified to Verified, and it is
        # not optional or inferrable: GitHub checks the signature against the
        # keys listed under SSH *signing* keys on the account. A key you already
        # use for authentication does not count, even byte-for-byte identical —
        # it has to be listed under both types. Doing it here means bringing
        # your existing key needs nothing done on github.com.
        #
        # Best-effort on purpose. It needs admin:ssh_signing_key on the PAT
        # (fine-grained: "SSH signing keys" read+write), which a token minted for
        # `git push` will not have. Every failure path prints the manual step and
        # boots on rather than holding the box hostage to a scope.
        if [ -n "${GITHUB_TOKEN:-}" ] && [ -x /usr/local/bin/gh ]; then
          # Match on the key body alone, never the whole line: the comment field
          # differs between the copy on your laptop and the one ssh-keygen -y
          # regenerates here, so comparing lines would re-upload every boot.
          PUB_BODY="$(awk '{print $2}' "${SIGNING_KEY}.pub")"
          # No --paginate: one page of 100 is far past anyone's signing-key count,
          # and paginating an array endpoint hands jq concatenated arrays.
          # shellcheck disable=SC2016  # $HOME is expanded by the dev user's shell.
          SIGNING_KEYS_JSON="$(as_dev '. "$HOME/.devaloy_secrets" && gh api "/user/ssh_signing_keys?per_page=100"' 2>/dev/null || true)"

          if printf '%s' "${SIGNING_KEYS_JSON}" | jq -e --arg k "${PUB_BODY}" \
               'any(.[]; (.key | split(" ")[1]) == $k)' >/dev/null 2>&1; then
            log "signing key is already registered on GitHub"
          else
            # shellcheck disable=SC2016  # as above.
            ADD_CMD='. "$HOME/.devaloy_secrets" && gh api --method POST /user/ssh_signing_keys'
            ADD_CMD="${ADD_CMD} -f title=$(sq "devaloy (${TS_HOSTNAME:-devaloy})")"
            ADD_CMD="${ADD_CMD} -f key=$(sq "$(cat "${SIGNING_KEY}.pub")")"
            ADD_OUT="$(as_dev "${ADD_CMD}" 2>&1 || true)"
            case "${ADD_OUT}" in
              # Also the path taken when the token can write but not read, so the
              # listing above came back empty and this POST was a no-op.
              *'already in use'*|*'already exists'*)
                log "signing key is already registered on GitHub" ;;
              *'"id"'*)
                log "registered the signing key on GitHub — commits will show as Verified" ;;
              *)
                log "WARNING: could not register the signing key on GitHub."
                log "WARNING: add ~/.ssh/devaloy_signing.pub by hand at"
                log "WARNING:   https://github.com/settings/ssh/new  (type: Signing Key)"
                log "WARNING: or give the PAT the admin:ssh_signing_key scope to"
                log "WARNING: let this happen on its own. Commits are signed either"
                log "WARNING: way; GitHub just shows them Unverified until it is done." ;;
            esac
          fi
        else
          log "GitHub marks these Verified only once the matching PUBLIC key is"
          log "added to your account as a SIGNING key (not an authentication key):"
          log "  https://github.com/settings/ssh/new"
        fi
      else
        rm -f "${SIGNING_KEY}" "${SIGNING_KEY}.pub"
        log "WARNING: GIT_SIGNING_SSH_KEY is not a usable key — commits stay unsigned."
        log "WARNING: it must be an OpenSSH private key with NO passphrase."
      fi
      ;;
    *)
      log "WARNING: GIT_SIGNING_SSH_KEY did not decode to an SSH private key."
      log "WARNING: expected base64 of the key file — commits stay unsigned."
      ;;
  esac
fi

# Reached both when no key is configured and when one failed to install, so a
# box that signed yesterday does not fail every commit today.
git_unset() { as_dev "git config --global --unset-all $(sq "$1") || true"; }
if [ ! -s "${SIGNING_KEY}" ]; then
  git_unset commit.gpgsign
  git_unset tag.gpgsign
  git_unset user.signingkey
  git_unset gpg.format
  git_unset gpg.ssh.allowedSignersFile
fi

# --- Orca headless runtime (only present when built with WITH_ORCA=true) ---
# Lets the Orca desktop and mobile apps talk to this box, which Tailscale SSH
# alone cannot do — they speak to a runtime, not a terminal.
#
# Silence is correct when the binary is absent: WITH_ORCA=false is the DEFAULT
# build, so a missing /usr/bin/orca-ide is the normal case and not a fault. Do
# not "improve" this into a warning — every stock box would nag about a package
# it was never asked to install.
#
# Runs after link-shims on purpose: Orca shells out to `codex` and `claude`, and
# `su -l -s /bin/sh` does NOT get the mise shims on PATH — only /usr/local/bin,
# which is exactly what link-shims mirrors them into. Start this any earlier and
# agents launched from an Orca client die with `spawn codex ENOENT`.
ORCA_BIN="/usr/bin/orca-ide"
ORCA_PORT=6768

if [ -x "${ORCA_BIN}" ]; then
  ORCA_IP="$(tailscale --socket="${TS_SOCKET}" ip -4 2>/dev/null | head -1 || true)"
  if [ -n "${ORCA_IP}" ]; then
    (
      # Explicit, NOT inherited — and the value is deliberate. The container
      # starts at -500 to keep tailscaled off the OOM killer's list, and
      # oom_score_adj is inherited by children, so leaving this alone would make
      # Orca exactly as protected as the daemon that is your only way back in.
      # Interactive shells raise themselves to 0 (see .devaloy_env above), so
      # the ordering we want is: runaway build (0) dies first, then Orca (-250),
      # and tailscaled (-500) last. Raising above an inherited value is
      # unprivileged, so this needs no CAP_SYS_RESOURCE.
      echo -250 > /proc/self/oom_score_adj 2>/dev/null || true

      # Unbounded restart loop: there is no runtime kill switch by design, and
      # the sleep is what stops a crash-loop spinning hot. To actually stop it,
      # `docker compose stop` or rebuild with WITH_ORCA=false — see the README.
      #
      # xvfb-run because Electron wants an X display even headless; the sandbox
      # is KEPT (never --no-sandbox) and works because compose already sets
      # seccomp=unconfined for Codex's bubblewrap, which is the same user
      # namespace permission Chromium's sandbox needs.
      # SHELL is set explicitly because as_dev runs `su -l -s /bin/sh`, and su
      # exports whatever it was given with -s. Orca spawns its terminals from
      # $SHELL rather than /etc/passwd, so without this every terminal opened
      # from the desktop or mobile app lands in sh instead of the dev user's
      # actual login shell. The -s /bin/sh itself has to stay — see as_dev.
      while true; do
        as_dev "SHELL=/usr/bin/zsh LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a '${ORCA_BIN}' serve \
          --port '${ORCA_PORT}' --pairing-address '${ORCA_IP}'" || true
        log "WARNING: orca serve exited — restarting in 10s"
        sleep 10
      done
    ) &
    # Both the desktop and the phone pair off this one server's own output —
    # there is no second command to run. A second `orca serve` in this container
    # hits Electron's single-instance lock and exits, and there is no `orca
    # pair` subcommand. --mobile-pairing is a flag on THIS launch that swaps the
    # code for a mobile-scoped one; adding it here costs the desktop's default
    # link, which is why it is not here.
    log "Orca server on ${ORCA_IP}:${ORCA_PORT} — pair both the desktop and the"
    log "phone from this server's own log: the 'Pairing URL' line for the"
    log "desktop, and the orca:// link or 'Web client URL' line for the phone."
  else
    # Same call as tailscale up's own failure path: an advertised address that
    # nothing can route to is worse than no server at all, because the client
    # fails at pairing time rather than here where the log explains why.
    log "WARNING: no tailnet IPv4 — not starting orca serve."
    log "WARNING: fix the tailscale failure above, then restart the container."
  fi
fi

log "devaloy is up. Connect with: ssh dev@${TS_HOSTNAME:-devaloy}"
wait "${TAILSCALED_PID}"
